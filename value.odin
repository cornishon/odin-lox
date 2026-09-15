package olox

import "core:fmt"

Value :: union {
	^Object,
	f64,
	bool,
}

value_formatter :: proc(fi: ^fmt.Info, arg: any, verb: rune) -> bool {
	value := arg.(Value) or_return
	switch v in value {
	case f64:
		fmt.fmt_value(fi, v, verb == 'q' ? 'v' : verb)
	case bool:
		fmt.fmt_value(fi, v, verb == 'q' ? 'v' : verb)
	case ^Object:
		fmt.fmt_value(fi, v.variant, verb)
	case:
		fi.ignore_user_formatters = true
		fmt.fmt_value(fi, arg, verb == 'q' ? 'v' : verb)
	}
	return true
}

value_type :: proc(value: Value) -> string {
	switch v in value {
	case f64:
		return "number"
	case bool:
		return "bool"
	case ^Object:
		switch v in v.variant {
		case ^String:
			return "string"
		case ^Function:
			return "function"
		case ^Native:
			return "native function"
		case ^Closure:
			return "closure"
		case ^Upvalue:
			return "upvalue"
		case ^Class:
			return "class" // maybe should be the class name?
		case ^Instance:
			return v.class.name.data
		case ^Bound_Method:
			return "method"
		}
	}
	return "nil"
}

value_as :: proc($T: typeid, value: Value) -> (^T, bool) {
	#partial switch v in value {
	case ^Object:
		return v.variant.(^T)
	}
	return nil, false
}

value_is_falsey :: proc(value: Value) -> bool {
	#partial switch v in value {
	case bool:
		return !v
	case nil:
		return true
	case:
		return false
	}
}
