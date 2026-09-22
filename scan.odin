package olox

import "base:intrinsics"

Scanner :: struct {
	source: string,
	start: int,
	current: int,
	line: u32,
}

scanner_init :: proc(source: string) -> Scanner {
	return {
		source = source,
		line = 1,
	}
}

scan_token :: proc(s: ^Scanner) -> Token {
	skip_whitespace(s)
	s.start = s.current
	switch advance(s) {
	case '(':
		return make_token(s, .Left_Paren)
	case ')':
		return make_token(s, .Right_Paren)
	case '{':
		return make_token(s, .Left_Brace)
	case '}':
		return make_token(s, .Right_Brace)
	case '[':
		return make_token(s, .Left_Bracket)
	case ']':
		return make_token(s, .Right_Bracket)
	case ';':
		return make_token(s, .Semicolon)
	case ',':
		return make_token(s, .Comma)
	case '.':
		return make_token(s, .Dot)
	case '-':
		return make_token(s, .Minus)
	case '+':
		return make_token(s, .Plus)
	case '/':
		return make_token(s, .Slash)
	case '*':
		return make_token(s, .Star)
	case '!':
		return make_token(s, .Bang_Equal if (match(s, '=')) else .Bang)
	case '=':
		return make_token(s, .Equal_Equal if (match(s, '=')) else .Equal)
	case '<':
		return make_token(s, .Less_Equal if (match(s, '=')) else .Less)
	case '>':
		return make_token(s, .Greater_Equal if (match(s, '=')) else .Greater)
	case '"':
		return scan_string(s)
	case '\'':
		return scan_rune(s)
	case '0' ..= '9':
		return scan_number(s)
	case 'a' ..= 'z', 'A' ..= 'Z', '_':
		return scan_identifier(s)
	case 0:
		return make_token(s, .Eof)
	case:
		return error_token(s, "Unexpected character.")
	}
}

find_matching :: proc(s: ^Scanner, $delim: byte) -> bool {
	#assert(delim != '\\')
	for s.current < len(s.source) {
		switch advance(s) {
		case '\\': advance(s)
		case delim: return true
		}
	}
	return false
}

scan_string :: proc(s: ^Scanner) -> Token {
	if !find_matching(s, '"') {
		return error_token(s, "Unterminated string.")
	}
	return make_token(s, .String)
}

scan_rune :: proc(s: ^Scanner) -> Token {
	if !find_matching(s, '\'') {
		return error_token(s, "Unterminated character literal.")
	}
	return make_token(s, .Rune)
}

scan_number :: proc(s: ^Scanner) -> Token {
	for is_digit(getc(s)) {
		advance(s)
	}
	if getc(s, 0) == '.' && is_digit(getc(s, 1)) {
		advance(s)
		for is_digit(getc(s)) {
			advance(s)
		}
	}
	return make_token(s, .Number)
}

scan_identifier :: proc(s: ^Scanner) -> Token {
	for is_alpha(getc(s)) || is_digit(getc(s)) {
		advance(s)
	}
	return make_token(s, keyword_or_identifier(s))
}

keyword_or_identifier :: proc(s: ^Scanner) -> Token_Kind {
	switch s.source[s.start] {
	case 'a':
		return check_keyword(s, 1, "nd", .And)
	case 'c':
		return check_keyword(s, 1, "lass", .Class)
	case 'e':
		return check_keyword(s, 1, "lse", .Else)
	case 'i':
		return check_keyword(s, 1, "f", .If)
	case 'n':
		return check_keyword(s, 1, "il", .Nil)
	case 'o':
		return check_keyword(s, 1, "r", .Or)
	case 'p':
		return check_keyword(s, 1, "rint", .Print)
	case 'r':
		return check_keyword(s, 1, "eturn", .Return)
	case 's':
		return check_keyword(s, 1, "uper", .Super)
	case 'v':
		return check_keyword(s, 1, "ar", .Var)
	case 'w':
		return check_keyword(s, 1, "hile", .While)
	case 'f':
		if (s.current - s.start > 1) {
			switch s.source[s.start + 1] {
			case 'a':
				return check_keyword(s, 2, "lse", .False)
			case 'o':
				return check_keyword(s, 2, "r", .For)
			case 'u':
				return check_keyword(s, 2, "n", .Fun)
			}
		}
	case 't':
		if (s.current - s.start > 1) {
			switch s.source[s.start + 1] {
			case 'h':
				return check_keyword(s, 2, "his", .This)
			case 'r':
				return check_keyword(s, 2, "ue", .True)
			}
		}
	}
	return .Identifier
}

check_keyword :: proc(s: ^Scanner, off: int, t: string, kind: Token_Kind) -> Token_Kind {
	if s.current - s.start != off + len(t) {
		return .Identifier
	}
	if s.source[s.start + off:][:len(t)] == t {
		return kind
	}
	return .Identifier
}

is_digit :: proc(c: byte) -> bool {
	switch c {
	case '0' ..= '9':
		return true
	}
	return false
}

is_alpha :: proc(c: byte) -> bool {
	switch c {
	case 'a' ..= 'z':
		return true
	case 'A' ..= 'Z':
		return true
	case '_':
		return true
	}
	return false
}

skip_whitespace :: proc(s: ^Scanner) {
	for {
		switch getc(s) {
		case ' ', '\r', '\n', '\t':
			advance(s)
		case '/':
			if getc(s, 1) != '/' {
				return
			}
			for s.current < len(s.source) && advance(s) != '\n' {
			}
		case:
			return
		}
	}
}

@(private = "file")
getc :: proc(s: ^Scanner, offset := 0) -> byte {
	if intrinsics.unlikely(s.current + offset >= len(s.source)) {
		return 0
	}
	return s.source[s.current + offset]
}

@(private = "file")
advance :: proc(s: ^Scanner) -> byte {
	defer s.current += 1
	c := getc(s)
	s.line += u32(c == '\n')
	return c
}

@(private = "file")
match :: proc(s: ^Scanner, expected: byte) -> bool {
	if getc(s) != expected {
		return false
	}
	s.current += 1
	return true
}

make_token :: proc(s: ^Scanner, kind: Token_Kind) -> Token {
	return {
		line = s.line,
		kind = kind,
		text = kind == .Eof ? "" : s.source[s.start:s.current],
	}
}

error_token :: proc(s: ^Scanner, msg: string) -> Token {
	return {
		line = s.line,
		kind = .Error,
		text = msg,
	}
}
