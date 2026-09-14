package olox

Value :: union {
	^Object,
	f64,
	bool,
}

value_as_string :: proc(value: Value) -> (^String, bool) {
	#partial switch v in value {
	case ^Object:
		return v.variant.(^String)
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
