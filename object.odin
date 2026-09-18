#+feature global-context
package olox

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:reflect"
import "core:strings"

_ :: reflect
_ :: runtime

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
	text: string,
	hash: u32,
}

Function :: struct {
	using obj: Object,
	name: ^String,
	arity: int,
	upvalue_count: int,
	chunk: Chunk,
}

Native_Fn :: proc "contextless" (args: []Value) -> (result: Value, ok: bool)

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

obj_create :: proc "contextless" ($T: typeid) -> ^T {
	context = vm.ctx
	o := new(T)
	o.variant = o
	o.next_obj = vm.objects
	vm.objects = &o.obj
	when DEBUG_LOG_GC {
		fmt.printfln("%p allocate %d for %v", rawptr(o), size_of(T), typeid_of(T))
	}
	return o
}

obj_destroy :: proc(o: ^Object) {
	when DEBUG_LOG_GC {
		fmt.printfln("%p free type %v", rawptr(o), reflect.union_variant_typeid(o.variant))
	}
	context.allocator = lox_allocator()
	switch v in o.variant {
	case ^String:
		delete(v.text)
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

allocate_string :: proc "contextless" (text: string, hash: u32) -> ^String {
	s := obj_create(String)
	s.text = text
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

intern_string :: proc "contextless" (text: string) -> ^String {
	h := hash.fnv32(transmute([]u8)text)
	interned := table_find_string(&vm.strings, text, h)
	if interned != nil {
		return interned
	}
	context = vm.ctx
	cloned := strings.clone(text)
	return allocate_string(cloned, h)
}

new_function :: proc "contextless" () -> ^Function {
	f := obj_create(Function)
	chunk_init(&f.chunk)
	return f
}

new_closure :: proc "contextless" (fn: ^Function) -> ^Closure {
	context = vm.ctx
	upvalues := make([]^Upvalue, fn.upvalue_count)
	o := obj_create(Closure)
	o.function = fn
	o.upvalues = upvalues
	return o
}

new_bound_method :: proc "contextless" (receiver: Value, method: ^Closure) -> ^Bound_Method {
	o := obj_create(Bound_Method)
	o.receiver = receiver
	o.method = method
	return o
}

new_class :: proc "contextless" (name: ^String) -> ^Class {
	o := obj_create(Class)
	o.name = name
	table_init(&o.methods)
	return o
}

new_instance :: proc "contextless" (class: ^Class) -> ^Instance {
	o := obj_create(Instance)
	o.class = class
	table_init(&o.fields)
	return o
}

new_upvalue :: proc "contextless" (slot: ^Value) -> ^Upvalue {
	o := obj_create(Upvalue)
	o.location = slot
	return o
}

new_native :: proc "contextless" (arity: int, f: Native_Fn) -> ^Native {
	o := obj_create(Native)
	o.arity = arity
	o.call = f
	return o
}

obj_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	context.allocator = vm.backing_allocator
	o := arg.(^Object) or_return
	if o == nil {
		fmt.wprint(fi.writer, "nil")
		return true
	}
	switch v in o.variant {
	case ^String:
		fmt.fmt_string(fi, v.text, verb)
	case ^Function:
		fi.n += fmt.wprintf(fi.writer, "<fun %s>", v.name.text)
	case ^Native:
		fmt.fmt_string(fi, "<native>", verb)
	case ^Closure:
		fi.n += fmt.wprintf(fi.writer, "<fun %s>", v.function.name.text)
	case ^Upvalue:
		fmt.fmt_string(fi, "upvalue", verb)
	case ^Class:
		fi.n += fmt.wprintf(fi.writer, "class %s", v.name.text)
	case ^Instance:
		fi.n += fmt.wprintf(fi.writer, "%s instance", v.class.name.text)
	case ^Bound_Method:
		fi.n += fmt.wprintf(fi.writer, "<fun %s>", v.method.function.name.text)
	case:
		fi.n += fmt.wprintf(fi.writer, "CORRUPTED OBJECT at %p", rawptr(o))
	}
	return true
}

formatters: map[typeid]fmt.User_Formatter

@(init)
set_formatters :: proc() {
	fmt.set_user_formatters(&formatters)
	fmt.register_user_formatter(^Object, obj_formatter)
}

@(fini)
delete_formatters :: proc() {
	delete(formatters)
}
