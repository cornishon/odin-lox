package olox

import "base:runtime"
import "core:fmt"
import "core:io"
import "core:math"
import "core:mem"
import "core:strings"
import "core:time"

FRAMES_MAX :: 64
STACK_MAX :: FRAMES_MAX * 256

@(thread_local)
vm: struct {
	initialized: bool,
	objects: ^Object,
	open_upvalues: ^Upvalue,
	strings: Table,
	globals: Table,
	init_string: ^String,
	stdout: io.Writer,
	ctx: runtime.Context,

	// gc
	bytes_allocated: int,
	next_gc: int,
	backing_allocator: mem.Allocator,
	gray_stack: [dynamic]^Object,

	// runtime state
	stack: [STACK_MAX]Value,
	stack_top: [^]Value,
	frames: [FRAMES_MAX]Call_Frame,
	frame: ^Call_Frame,
	frame_count: int,
}

Call_Frame :: struct #all_or_none {
	closure: ^Closure,
	ip: [^]u8,
	slots: [^]Value,
	consts: [^]Value,
	upvalues: [^]^Upvalue,
}

vm_init :: proc(stdout: io.Writer, backing_allocator := context.allocator) {
	assert(!vm.initialized)
	defer vm.initialized = true

	vm.backing_allocator = backing_allocator
	vm.gray_stack.allocator = backing_allocator

	vm.ctx = context
	vm.ctx.allocator = lox_allocator()

	reset_stack()
	table_init(&vm.globals)
	table_init(&vm.strings)
	vm.init_string = intern_string("init")
	vm.next_gc = 1024 * 1024
	vm.stdout = stdout

	define_native("clock", 0, proc "contextless" (args: []Value) -> (Value, bool) {
		clock := f64(time.tick_now()._nsec) / 1e9
		return clock, true
	})

	define_native("sqrt", 1, proc "contextless" (args: []Value) -> (Value, bool) {
		if x, is_num := args[0].(f64); is_num && x >= 0 {
			return math.sqrt(x), true
		}
		return 0, runtime_error("Argument must be a non-negative number, but got: %q", args[0])
	})

	define_native("typeof", 1, proc "contextless" (args: []Value) -> (Value, bool) {
		return intern_string(value_type(args[0])), true
	})
}

vm_destroy :: proc() {
	io.flush(vm.stdout)
	table_destroy(&vm.globals)
	table_destroy(&vm.strings)
	vm.init_string = nil
	for curr := vm.objects; curr != nil; {
		next := curr.next_obj
		obj_destroy(curr)
		curr = next
	}
	delete(vm.gray_stack)
	vm = {}
}

vm_interpret :: proc(source: string) -> bool {
	assert(vm.initialized)
	function := compile(source) or_return
	reset_stack()
	push(function)
	c := new_closure(function)
	pop_()
	push(c)
	call_closure(c, 0)
	return exec(enter_frame(vm.stack_top, &vm.frames[vm.frame_count - 1]))
}

push :: #force_inline proc "contextless" (value: Value) {
	vm.stack_top[0] = value
	vm.stack_top = vm.stack_top[1:]
}

pop_ :: #force_inline proc "contextless" () -> Value {
	vm.stack_top = vm.stack_top[-1:]
	return vm.stack_top[0]
}

peek :: #force_inline proc "contextless" (distance: int) -> Value {
	return vm.stack_top[-distance - 1]
}

enter_frame :: proc "contextless" (
	sp: [^]Value,
	fp: ^Call_Frame,
) -> (
	sp_: [^]Value,
	ip_: [^]u8,
	consts: [^]Value,
	locals: [^]Value,
	upvalues: [^]^Upvalue,
) {
	return sp, fp.ip, fp.consts, fp.slots, fp.upvalues
}

call_closure :: proc "contextless" (c: ^Closure, argc: int) -> bool {
	if argc != c.function.arity {
		return runtime_error("Expected %d arguments but got %d.", c.function.arity, argc)
	}
	if vm.frame_count == FRAMES_MAX {
		return runtime_error("Stack overflow.")
	}
	vm.frame = &vm.frames[vm.frame_count]
	vm.frame_count += 1
	vm.frame^ = {
		closure = c,
		ip = raw_data(c.function.chunk.code),
		slots = vm.stack_top[-argc - 1:],
		consts = raw_data(c.function.chunk.consts),
		upvalues = raw_data(c.upvalues),
	}
	return true
}

call_value :: proc "contextless" (callee: Value, argc: int) -> bool {
	if obj, is_obj := callee.(^Object); is_obj {
		switch callable in obj.variant {
		case ^Closure:
			return call_closure(callable, argc)
		case ^Function:
			panic_contextless("tried to call a bare function")
		case ^Bound_Method:
			vm.stack_top[-argc - 1] = callable.receiver
			return call_closure(callable.method, argc)
		case ^Class:
			vm.stack_top[-argc - 1] = new_instance(callable)
			if val, ok := table_get(&callable.methods, vm.init_string); ok {
				initializer := value_as(Closure, val)
				return call_closure(initializer, argc)
			} else if argc != 0 {
				return runtime_error("Expected 0 arguments but got %d.", argc)
			}
			return true
		case ^Native:
			if argc != callable.arity {
				return runtime_error("Expected %d arguments but got %d.", callable.arity, argc)
			}
			result := callable.call(vm.stack_top[-argc:0]) or_return
			vm.stack_top = vm.stack_top[-argc - 1:]
			push(result)
			return true
		case ^Instance:
		case ^String:
		case ^Upvalue:
		}
	}
	return runtime_error("Can only call functions and classes, but got: %v", value_type(callee))
}

invoke :: proc "contextless" (name: ^String, argc: int) -> bool {
	receiver := peek(argc)
	if instance, ok := value_as(Instance, receiver); ok {
		if value, was_field := table_get(&instance.fields, name); was_field {
			vm.stack_top[-argc - 1] = value
			return call_value(value, argc)
		}
		return invoke_from_class(instance.class, name, argc)
	}
	return runtime_error("Only instances have methods.")
}

invoke_from_class :: proc "contextless" (class: ^Class, name: ^String, argc: int) -> bool {
	if val, ok := table_get(&class.methods, name); ok {
		method := value_as(Closure, val)
		return call_closure(method, argc)
	}
	return runtime_error("Undefined property %q.", name)
}

bind_method :: proc "contextless" (class: ^Class, name: ^String) -> bool {
	method, ok := table_get(&class.methods, name)
	if !ok {
		return runtime_error("Undefined property %q.", name)
	}
	closure := value_as(Closure, method)
	bound := new_bound_method(peek(0), closure)
	pop_()
	push(bound)
	return true
}

capture_upvalue :: proc "contextless" (slot: ^Value) -> ^Upvalue {
	prev_uv: ^Upvalue
	uv := vm.open_upvalues
	for uv != nil && uv.location > slot {
		prev_uv = uv
		uv = uv.next_open
	}
	if uv != nil && uv.location == slot {
		return uv
	}
	created_uv := new_upvalue(slot)
	created_uv.next_open = uv
	if prev_uv == nil {
		vm.open_upvalues = created_uv
	} else {
		prev_uv.next_open = created_uv
	}
	return created_uv
}

close_upvalues :: proc "contextless" (last: ^Value) {
	for vm.open_upvalues != nil && vm.open_upvalues.location >= last {
		uv := vm.open_upvalues
		uv.closed = uv.location^
		uv.location = &uv.closed
		vm.open_upvalues = uv.next_open
	}
}

frame_chunk :: #force_inline proc "contextless" () -> ^Chunk {
	return &vm.frame.closure.function.chunk
}

reset_stack :: proc() {
	vm.stack_top = &vm.stack[0]
	vm.frame = &vm.frames[0]
	vm.frame_count = 0
}

runtime_error :: proc "contextless" (format: string, args: ..any) -> bool {
	context = runtime.default_context()
	instr := mem.ptr_sub(vm.frame.ip, raw_data(frame_chunk().code)) - 1
	line := chunk_get_line(frame_chunk(), instr)
	fmt.eprintf("[line %d]: Runtime error: ", line)
	fmt.eprintfln(format, ..args)

	#reverse for frame, i in vm.frames[:vm.frame_count] {
		fun := frame.closure.function
		instr = mem.ptr_sub(frame.ip, raw_data(fun.chunk.code)) - 1
		fmt.eprintf("[line %d] in ", chunk_get_line(&fun.chunk, instr))
		if i == 0 {
			fmt.eprintln("<script>")
		} else {
			fmt.eprintfln("%s()", fun.name)
		}
	}

	reset_stack()
	return false
}

define_native :: proc(name: string, arity: int, implementation: Native_Fn) {
	// pushing on to the stack so that GC know we're still using them
	name := intern_string(name)
	push(name)
	impl := new_native(arity, implementation)
	push(impl)
	table_set(&vm.globals, name, impl)
	pop_()
	pop_()
}

Operation :: proc "preserve/none" (
	sp: [^]Value,
	ip: [^]u8,
	consts: [^]Value,
	locals: [^]Value,
	upvalues: [^]^Upvalue,
) -> bool

// odinfmt: disable
@(rodata)
optable := [Opcode]Operation {
	.NIL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = nil
		return #must_tail exec(sp[1:], ip[1:], consts, locals, upvalues)
	},
	.FALSE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = false
		return #must_tail exec(sp[1:], ip[1:], consts, locals, upvalues)
	},
	.TRUE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = true
		return #must_tail exec(sp[1:], ip[1:], consts, locals, upvalues)
	},
	.CONST = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = consts[ip[1]]
		return #must_tail exec(sp[1:], ip[2:], consts, locals, upvalues)
	},
	.POP = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
	},
	.RETURN = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		result := sp[-1]
		close_upvalues(locals)
		if vm.frame_count -= 1; vm.frame_count == 0 {
			vm.stack_top = &vm.stack[0]
			return true
		}
		vm.stack_top = locals
		vm.stack_top[0] = result
		vm.frame = &vm.frames[vm.frame_count - 1]
		return #must_tail exec(enter_frame(vm.stack_top[1:], vm.frame))
	},
	.PRINT = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		context = vm.ctx
		fmt.wprintln(vm.stdout, sp[-1])
		return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
	},
	.GET_LOCAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = locals[ip[1]]
		return #must_tail exec(sp[1:], ip[2:], consts, locals, upvalues)
	},
	.SET_LOCAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		locals[ip[1]] = sp[-1]
		return #must_tail exec(sp[:], ip[2:], consts, locals, upvalues)
	},
	.DEF_GLOBAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		name := value_as(String, consts[ip[1]])
		vm.stack_top = sp // gc
		table_set(&vm.globals, name, sp[-1])
		return #must_tail exec(sp[-1:], ip[2:], consts, locals, upvalues)
	},
	.SET_GLOBAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		name := value_as(String, consts[ip[1]])
		vm.stack_top = sp // gc
		if table_set(&vm.globals, name, sp[-1]) {
			table_remove(&vm.globals, name)
			return runtime_error("Undefined variable '%s'", name)
		}
		return #must_tail exec(sp[:], ip[2:], consts, locals, upvalues)
	},
	.GET_UPVALUE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[0] = upvalues[ip[1]].location^
		return #must_tail exec(sp[1:], ip[2:], consts, locals, upvalues)
	},
	.SET_UPVALUE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		upvalues[ip[1]].location^ = sp[-1]
		return #must_tail exec(sp[:], ip[2:], consts, locals, upvalues)
	},
	.GET_PROPERTY = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		instance, is_inst := value_as(Instance, sp[-1])
		if !is_inst {
			return runtime_error("Only instances have properties.")
		}
		name := value_as(String, consts[ip[1]])
		if value, ok := table_get(&instance.fields, name); ok {
			sp[-1] = value
		} else {
			vm.stack_top = sp // gc
			bind_method(instance.class, name) or_return
		}
		return #must_tail exec(sp[:], ip[2:], consts, locals, upvalues)
	},
	.SET_PROPERTY = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		instance, is_inst := value_as(Instance, sp[-2])
		if !is_inst {return runtime_error("Only instances have properties.")}
		name := value_as(String, consts[ip[1]])
		vm.stack_top = sp // gc
		table_set(&instance.fields, name, sp[-1])
		sp[-2] = sp[-1]
		return #must_tail exec(sp[-1:], ip[2:], consts, locals, upvalues)
	},
	.GET_SUPER = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		name := value_as(String, consts[ip[1]])
		superclass := value_as(Class, sp[-1])
		vm.stack_top = sp[-1:]
		bind_method(superclass, name) or_return
		return #must_tail exec(sp[-1:], ip[2:], consts, locals, upvalues)
	},
	.LOOP = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		offset := u16(ip[1] << 8) | u16(ip[2])
		return #must_tail exec(sp[:], ip[3 - offset:], consts, locals, upvalues)
	},
	.CALL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		argc := int(ip[1])
		vm.frame.ip = ip[2:]
		vm.stack_top = sp // gc
		call_value(sp[-argc - 1], argc) or_return
		return #must_tail exec(enter_frame(vm.stack_top, vm.frame))
	},
	.INVOKE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		method := value_as(String, consts[ip[1]])
		argc := int(ip[2])
		vm.stack_top = sp // gc
		vm.frame.ip = ip[3:]
		invoke(method, argc) or_return
		return #must_tail exec(enter_frame(vm.stack_top, vm.frame))
	},
	.SUPER_INVOKE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		method := value_as(String, consts[ip[1]])
		argc := int(ip[2])
		superclass := value_as(Class, sp[-1])
		vm.stack_top = sp[-1:] // gc
		vm.frame.ip = ip[3:]
		invoke_from_class(superclass, method, argc) or_return
		return #must_tail exec(enter_frame(vm.stack_top, vm.frame))
	},
	.CLOSURE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		fn := value_as(Function, consts[ip[1]])
		vm.stack_top = sp
		cl := new_closure(fn)
		sp[0] = cl
		for &uv, i in cl.upvalues {
			is_local := bool(ip[2 * i + 2])
			index := ip[2 * i + 3]
			if is_local {
				uv = capture_upvalue(&locals[index])
			} else {
				uv = upvalues[index]
			}
		}
		return #must_tail exec(sp[1:], ip[2 * len(cl.upvalues) + 2:], consts, locals, upvalues)
	},
	.CLOSE_UPVALUE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		close_upvalues(&sp[-1])
		return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
	},
	.JUMP = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		offset := u16(ip[1] << 8) | u16(ip[2])
		return #must_tail exec(sp[:], ip[3 + offset:], consts, locals, upvalues)
	},
	.JUMP_IF_NOT = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		offset := value_is_falsey(sp[-1]) ? u16(ip[1] << 8) | u16(ip[2]) : 0
		return #must_tail exec(sp[:], ip[3 + offset:], consts, locals, upvalues)
	},
	.EQUAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[-2] = sp[-2] == sp[-1]
		return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
	},
	.LESS = numeric_op,
	.GREATER = numeric_op,
	.SUB = numeric_op,
	.MUL = numeric_op,
	.DIV = numeric_op,
	.ADD = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		if b, b_ok := value_as(String, sp[-1]); b_ok {
			if a, a_ok := value_as(String, sp[-2]); a_ok {
				context = vm.ctx
				vm.stack_top = sp
				text := strings.concatenate({a.text, b.text})
				sp[-2] = take_string(text)
				return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
			}
		}
		return #must_tail numeric_op(sp[:], ip[:], consts, locals, upvalues)
	},
	.NOT = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		sp[-1] = value_is_falsey(sp[-1])
		return #must_tail exec(sp[:], ip[1:], consts, locals, upvalues)
	},
	.NEGATE = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		n, ok := sp[-1].(f64)
		if !ok {return runtime_error("Operand must be a number.")}
		sp[-1] = -n
		return #must_tail exec(sp[:], ip[1:], consts, locals, upvalues)
	},
	.CLASS = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		name := value_as(String, consts[ip[1]])
		vm.stack_top = sp // gc
		sp[0] = new_class(name)
		return #must_tail exec(sp[1:], ip[2:], consts, locals, upvalues)
	},
	.METHOD = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		method := sp[-1]
		class := value_as(Class, sp[-2])
		name := value_as(String, consts[ip[1]])
		vm.stack_top = sp // gc
		table_set(&class.methods, name, method)
		return #must_tail exec(sp[-1:], ip[2:], consts, locals, upvalues)
	},
	.INHERIT = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		superclass, is_class := value_as(Class, sp[-2])
		if !is_class {return runtime_error("Superclass must be a class.")}
		subclass := value_as(Class, sp[-1])
		vm.stack_top = sp // gc
		table_add_all(superclass.methods, &subclass.methods)
		return #must_tail exec(sp[-1:], ip[1:], consts, locals, upvalues)
	},
	.GET_GLOBAL = proc "preserve/none" (sp: [^]Value, ip: [^]u8, consts: [^]Value, locals: [^]Value, upvalues: [^]^Upvalue) -> bool {
		name := value_as(String, consts[ip[1]])
		v, ok := table_get(&vm.globals, name)
		if !ok {return runtime_error("Undefined variable '%s'", name)}
		sp[0] = v
		return #must_tail exec(sp[1:], ip[2:], consts, locals, upvalues)
	},
}
// odinfmt: enable

exec :: proc "preserve/none" (
	sp: [^]Value,
	ip: [^]u8,
	consts: [^]Value,
	locals: [^]Value,
	upvalues: [^]^Upvalue,
) -> bool {
	when DEBUG_TRACE_EXECUTION {
		context = vm.ctx
		for s := raw_data(&vm.stack); s < sp; s = s[1:] {
			fmt.printf("[ %v ]", s[0])
			if s > &vm.stack[10] {
				fmt.print("...")
				break
			}
		}
		fmt.printf("\n%v\n", Opcode(ip[0]))
	}
	return #must_tail optable[Opcode(ip[0])](sp, ip, consts, locals, upvalues)
}

check_arith :: proc "contextless" (a, b: Value) -> (n, m: f64, ok: bool) {
	if n, ok = a.(f64); ok {
		if m, ok = b.(f64); ok {
			return
		}
	}
	ta := value_type(a)
	tb := value_type(b)
	return 0, 0, runtime_error("Operands must be numbers, but got: %v and %v.", ta, tb)
}

numeric_op :: proc "preserve/none" (
	sp: [^]Value,
	ip: [^]u8,
	consts: [^]Value,
	locals: [^]Value,
	uvs: [^]^Upvalue,
) -> bool {
	a, b := check_arith(sp[-2], sp[-1]) or_return
	// odinfmt: disable
	#partial switch Opcode(ip[0]) {
	case .ADD:     sp[-2] = a + b
	case .SUB:     sp[-2] = a - b
	case .MUL:     sp[-2] = a * b
	case .DIV:     sp[-2] = a / b
	case .LESS:    sp[-2] = a < b
	case .GREATER: sp[-2] = a > b
	case: return runtime_error("Not a numeric op: %v", Opcode(ip[0]))
	}
	// odinfmt: enable
	return #must_tail exec(sp[-1:], ip[1:], consts, locals, uvs)
}
