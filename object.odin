#+feature global-context
package olox

import "core:fmt"
import "core:hash"
import "core:strings"

formatters: map[typeid]fmt.User_Formatter

@(init)
set_formatters :: proc() {
	fmt.set_user_formatters(&formatters)
	fmt.register_user_formatter(^Function, function_formatter)
	fmt.register_user_formatter(^String, string_formatter)
	fmt.register_user_formatter(^Object, obj_formatter)
}

@(fini)
delete_formatters :: proc() {
	delete(formatters)
}

Object :: struct {
	next: ^Object,
	variant: union {
		^String,
		^Function,
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
	chunk: Chunk,
}

obj_create :: proc($T: typeid) -> ^T {
	o := new(T)
	o.variant = o
	o.next = vm.objects
	vm.objects = &o.obj
	return o
}

obj_destroy :: proc(o: ^Object) {
	switch v in o.variant {
	case ^String:
		delete(v.data)
	case ^Function:
		chunk_deinit(&v.chunk)
	}
	free(o)
}

string_copy :: proc(text: string) -> ^String {
	h := hash.fnv32(transmute([]u8)text)
	interned := table_find_string(&vm.strings, text, h)
	if interned != nil {
		return interned
	}
	return _string_new(strings.clone(text), h)
}

string_concat :: proc(a, b: ^String) -> ^String {
	text := strings.concatenate({a.data, b.data})
	h := hash.fnv32(transmute([]u8)text)
	interned := table_find_string(&vm.strings, text, h)
	if interned != nil {
		delete(text)
		return interned
	}
	return _string_new(text, h)
}

@(private = "file")
_string_new :: proc(text: string, hash: u32) -> ^String {
	s := obj_create(String)
	s.data = text
	s.hash = hash
	table_set(&vm.strings, s, nil)
	return s
}

function_new :: proc(name: string) -> ^Function {
	f := obj_create(Function)
	f.name = string_copy(name)
	chunk_init(&f.chunk)
	return f
}

obj_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	o := arg.(^Object) or_return
	fi.n += fmt.wprint(fi.writer, o.variant)
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
	case 'v':
		fi.n += fmt.wprintf(fi.writer, "<fn %s>", v.name.data)
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, v, verb)
	}
	return true
}
