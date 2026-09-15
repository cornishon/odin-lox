#+feature global-context
package olox

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"

formatters: map[typeid]fmt.User_Formatter

@(init)
set_formatters :: proc() {
	fmt.set_user_formatters(&formatters)
	fmt.register_user_formatter(Value, value_formatter)
	fmt.register_user_formatter(^Function, function_formatter)
	fmt.register_user_formatter(^Native, native_formatter)
	fmt.register_user_formatter(^String, string_formatter)
	fmt.register_user_formatter(^Object, obj_formatter)
}

@(fini)
delete_formatters :: proc() {
	delete(formatters)
}

Object :: struct {
	next_obj: ^Object,
	is_marked: bool,
	variant: union {
		^String,
		^Function,
		^Native,
		^Closure,
		^Upvalue,
	},
}

String :: struct {
	using obj: Object,
	data: string,
	hash: u32,
}

Function :: struct {
	using obj: Object,
	name: ^String,
	arity: int,
	upvalue_count: int,
	chunk: Chunk,
}

Native_Fn :: proc(args: []Value) -> (result: Value, ok: bool)

Native :: struct {
	using obj: Object,
	arity: int,
	call: Native_Fn,
}

Closure :: struct {
	using obj: Object,
	function: ^Function,
	upvalues: []^Upvalue,
}

Upvalue :: struct {
	using obj: Object,
	location: ^Value,
	closed: Value,
	next_open: ^Upvalue,
}

obj_create :: proc($T: typeid) -> ^T {
	o := new(T, lox_allocator())
	o.variant = o
	o.next_obj = vm.objects
	vm.objects = &o.obj
	when DEBUG_LOG_GC {
		fmt.printfln("%p allocate %d for %v", o, size_of(T), typeid_of(T))
	}
	return o
}

obj_destroy :: proc(o: ^Object) {
	when DEBUG_LOG_GC {
		fmt.printfln("%p free type %v", o, reflect.union_variant_typeid(o.variant))
	}
	context.allocator = lox_allocator()
	switch v in o.variant {
	case ^String:
		delete(v.data)
		// regular free() does not pass allocation size to the allocator procedure,
		// which we rely on for tracking the total bytes allocated
		delete(mem.ptr_to_bytes(v))
	case ^Function:
		chunk_deinit(&v.chunk)
		delete(mem.ptr_to_bytes(v))
	case ^Closure:
		delete(v.upvalues)
		delete(mem.ptr_to_bytes(v))
	case ^Upvalue:
		delete(mem.ptr_to_bytes(v))
	case ^Native:
		delete(mem.ptr_to_bytes(v))
	}
}

allocate_string :: proc(text: string, hash: u32) -> ^String {
	s := obj_create(String)
	s.data = text
	s.hash = hash
	push(s); pop_()
	table_set(&vm.strings, s, nil)
	return s
}

take_string :: proc(text: string) -> ^String {
	h := hash.fnv32(transmute([]u8)text)
	interned := table_find_string(&vm.strings, text, h)
	if interned != nil {
		delete(text, lox_allocator())
		return interned
	}
	return allocate_string(text, h)
}

copy_string :: proc(text: string) -> ^String {
	h := hash.fnv32(transmute([]u8)text)
	interned := table_find_string(&vm.strings, text, h)
	if interned != nil {
		return interned
	}
	cloned := strings.clone(text, lox_allocator())
	return allocate_string(cloned, h)
}

new_function :: proc() -> ^Function {
	f := obj_create(Function)
	push(f); defer pop_()
	chunk_init(&f.chunk)
	return f
}

new_closure :: proc(fn: ^Function) -> ^Closure {
	upvalues := make([]^Upvalue, fn.upvalue_count, lox_allocator())
	o := obj_create(Closure)
	o.function = fn
	o.upvalues = upvalues
	return o
}

new_upvalue :: proc(slot: ^Value) -> ^Upvalue {
	o := obj_create(Upvalue)
	o.location = slot
	return o
}

new_native :: proc(arity: int, f: Native_Fn) -> ^Native {
	o := obj_create(Native)
	o.arity = arity
	o.call = f
	return o
}

obj_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	o := arg.(^Object) or_return
	fmt.fmt_value(fi, o.variant, verb)
	return true
}

string_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^String) or_return
	switch verb {
	case 's', 'v', 'q', 'x', 'X':
		fmt.fmt_string(fi, v.data, verb)
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, v, verb)
	}
	return true
}

function_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Function) or_return
	switch verb {
	case 'v', 's', 'q':
		if v.name != nil {
			fi.n += fmt.wprintf(fi.writer, "<fun %s>", v.name.data)
		} else {
			fi.n += fmt.wprintf(fi.writer, "<script>")
		}
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, v, verb)
	}
	return true
}

native_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Native) or_return
	switch verb {
	case 'v', 's', 'q':
		fi.n += fmt.wprint(fi.writer, "<native function>")
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, v, verb)
	}
	return true
}
