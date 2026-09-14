package olox

import "core:fmt"
import "core:io"
import "core:mem"

FRAMES_MAX :: 16
STACK_MAX :: FRAMES_MAX * 256

@(thread_local)
vm: struct {
	objects: ^Object,
	strings: Table,
	globals: Table,
	stdout: io.Writer,

	// runtime state
	stack: [STACK_MAX]Value,
	stack_top: [^]Value,
	frames: [FRAMES_MAX]Call_Frame,
	frame: ^Call_Frame,
	frame_count: int,
}

Call_Frame :: struct {
	function: ^Function,
	ip: [^]u8,
	slots: [^]Value,
}

vm_init :: proc(stdout: io.Writer, allocator := context.allocator) {
	vm.stdout = stdout
	table_init(&vm.strings, allocator)
	table_init(&vm.globals, allocator)
}

vm_destroy :: proc() {
	io.flush(vm.stdout)
	curr := vm.objects
	for curr != nil {
		next := curr.next
		obj_destroy(curr)
		curr = next
	}
	table_destroy(&vm.globals)
	table_destroy(&vm.strings)
	vm = {}
}

vm_interpret :: proc(source: string) -> bool {
	function := compile(source) or_return
	_reset_stack()
	push(function)
	vm.frame^ = {
		function = function,
		ip = raw_data(function.chunk.code),
		slots = &vm.stack[0],
	}
	vm.frame_count += 1
	return run()
}

run :: proc() -> bool {
	for {
		op := Opcode(read_byte())
		switch op {
		case .NIL:
			push(nil)
		case .FALSE:
			push(false)
		case .TRUE:
			push(true)
		case .POP:
			pop_()
		case .RETURN:
			return true
		case .CONST:
			push(read_const())
		case .PRINT:
			fmt.wprintln(vm.stdout, pop_())
		case .GET_LOCAL:
			slot := read_byte()
			push(vm.frame.slots[slot])
		case .SET_LOCAL:
			slot := read_byte()
			vm.frame.slots[slot] = peek(0)
		case .DEF_GLOBAL:
			name := read_string()
			table_set(&vm.globals, name, peek(0))
			pop_()
		case .GET_GLOBAL:
			name := read_string()
			if v, ok := table_get(&vm.globals, name); ok {
				push(v)
			} else {
				return runtime_error("Undefined variable '%s'", name)
			}
		case .SET_GLOBAL:
			name := read_string()
			if table_set(&vm.globals, name, peek(0)) {
				table_remove(&vm.globals, name)
				return runtime_error("Undefined variable '%s'", name)
			}
		case .LOOP:
			offset := read_short()
			vm.frame.ip = vm.frame.ip[-offset:]
		case .JUMP:
			offset := read_short()
			vm.frame.ip = vm.frame.ip[offset:]
		case .JUMP_IF_NOT:
			offset := read_short()
			if value_is_falsey(peek(0)) {
				vm.frame.ip = vm.frame.ip[offset:]
			}
		case .EQUAL:
			b := pop_()
			a := pop_()
			push(a == b)
		case .LESS:
			a, b := pop_numbers() or_return
			push(a < b)
		case .GREATER:
			a, b := pop_numbers() or_return
			push(a > b)
		case .ADD:
			if b, b_ok := value_as_string(peek(0)); b_ok {
				if a, a_ok := value_as_string(peek(1)); a_ok {
					vm.stack_top = vm.stack_top[-2:]
					push(string_concat(a, b))
					continue
				}
			}
			a, b := pop_numbers() or_return
			push(a + b)
		case .SUB:
			a, b := pop_numbers() or_return
			push(a - b)
		case .MUL:
			a, b := pop_numbers() or_return
			push(a * b)
		case .DIV:
			a, b := pop_numbers() or_return
			push(a / b)
		case .NOT:
			push(value_is_falsey(pop_()))
		case .NEGATE:
			if n, ok := peek(0).(f64); ok {
				pop_(); push(-n)
			} else {
				return runtime_error("Operand must be a number.")
			}
		}
	}
}

pop_numbers :: proc() -> (a, b: f64, ok: bool) {
	a_ok, b_ok: bool
	if b, b_ok = peek(0).(f64); b_ok {
		if a, a_ok = peek(1).(f64); a_ok {
			vm.stack_top = vm.stack_top[-2:]
			return a, b, true
		}
	}
	return 0, 0, runtime_error("Operands must be numbers.")
}

read_byte :: #force_inline proc "contextless" () -> byte {
	defer vm.frame.ip = vm.frame.ip[1:]
	return vm.frame.ip[0]
}

read_short :: #force_inline proc "contextless" () -> u16 {
	defer vm.frame.ip = vm.frame.ip[2:]
	return u16(vm.frame.ip[0]) << 8 | u16(vm.frame.ip[1])
}

read_const :: #force_inline proc "contextless" () -> Value {
	return frame_chunk().consts[read_byte()]
}

read_string :: #force_inline proc "contextless" () -> ^String {
	return read_const().(^Object).variant.(^String)
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

frame_chunk :: #force_inline proc "contextless" () -> ^Chunk {
	return &vm.frame.function.chunk
}

_reset_stack :: proc() {
	vm.stack_top = &vm.stack[0]
	vm.frame = &vm.frames[0]
	vm.frame_count = 0
}

runtime_error :: proc(format: string, args: ..any) -> bool {
	instr := mem.ptr_sub(vm.frame.ip, raw_data(frame_chunk().code)) - 1
	line := chunk_get_line(frame_chunk(), instr)
	fmt.eprintf("[line %d]: Runtime error: ", line)
	fmt.eprintfln(format, args)
	_reset_stack()
	return false
}
