package olox

Value :: union {
	^Object,
	f64,
	bool,
}

value_type :: proc "contextless" (value: Value) -> string {
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
			return v.class.name.text
		case ^Bound_Method:
			return "method"
		}
	}
	return "nil"
}

value_as :: proc "contextless" ($T: typeid, value: Value) -> (^T, bool) #optional_ok {
	#partial switch v in value {
	case ^Object:
		return v.variant.(^T)
	}
	return nil, false
}

value_is_falsey :: proc "contextless" (value: Value) -> bool {
	#partial switch v in value {
	case bool:
		return !v
	case nil:
		return true
	case:
		return false
	}
}
