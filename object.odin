#+feature global-context
package olox

import "core:fmt"
import "core:hash"
import "core:mem"
import "core:strings"

Object :: struct {
	next_obj: ^Object,
	is_marked: bool,
	variant: Object_Variant,
}

Object_Variant :: union {
	^String,
	^Function,
	^Native,
	^Closure,
	^Upvalue,
	^Class,
	^Instance,
	^Bound_Method,
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

Class :: struct {
	using obj: Object,
	name: ^String,
	methods: Table,
}

Instance :: struct {
	using obj: Object,
	class: ^Class,
	fields: Table,
}

Bound_Method :: struct {
	using obj: Object,
	receiver: Value,
	method: ^Closure,
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
	case ^Class:
		table_destroy(&v.methods)
		delete(mem.ptr_to_bytes(v))
	case ^Instance:
		table_destroy(&v.fields)
		delete(mem.ptr_to_bytes(v))
	case ^Bound_Method:
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

intern_string :: proc(text: string) -> ^String {
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

new_bound_method :: proc(receiver: Value, method: ^Closure) -> ^Bound_Method {
	o := obj_create(Bound_Method)
	o.receiver = receiver
	o.method = method
	return o
}

new_class :: proc(name: ^String) -> ^Class {
	o := obj_create(Class)
	o.name = name
	return o
}

new_instance :: proc(class: ^Class) -> ^Instance {
	o := obj_create(Instance)
	o.class = class
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
	return variant_formatter(fi, v, verb, v.data)
}

function_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Function) or_return
	if v.name == nil {
		return variant_formatter(fi, v, verb, "<script>")
	} else {
		return variant_formatter(fi, v, verb, "<fun %s>", v.name.data)
	}
}

closure_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Closure) or_return
	fmt.fmt_value(fi, v.function, verb)
	return true
}

beound_method_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Bound_Method) or_return
	fmt.fmt_value(fi, v.method.function, verb)
	return true
}

upvalue_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Upvalue) or_return
	return variant_formatter(fi, v, verb, "upvalue")
}

native_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Native) or_return
	return variant_formatter(fi, v, verb, "<native function>")
}

class_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Class) or_return
	return variant_formatter(fi, v, verb, "class %s", v.name.data)
}

instance_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	v := arg.(^Instance) or_return
	return variant_formatter(fi, v, verb, "%s instance", v.class.name.data)
}

variant_formatter :: proc(
	fi: ^fmt.Info,
	v: Object_Variant,
	verb: rune,
	format: string,
	args: ..any,
) -> bool {
	switch verb {
	case 'v', 's', 'q':
		fi.n += fmt.wprintf(fi.writer, format, ..args)
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, v, verb)
	}
	return true
}

formatters: map[typeid]fmt.User_Formatter

@(init)
set_formatters :: proc() {
	fmt.set_user_formatters(&formatters)
	fmt.register_user_formatter(Value, value_formatter)
	fmt.register_user_formatter(^Object, obj_formatter)
	fmt.register_user_formatter(^String, string_formatter)
	fmt.register_user_formatter(^Function, function_formatter)
	fmt.register_user_formatter(^Native, native_formatter)
	fmt.register_user_formatter(^Closure, closure_formatter)
	fmt.register_user_formatter(^Bound_Method, beound_method_formatter)
	fmt.register_user_formatter(^Upvalue, upvalue_formatter)
	fmt.register_user_formatter(^Class, class_formatter)
}

@(fini)
delete_formatters :: proc() {
	delete(formatters)
}
