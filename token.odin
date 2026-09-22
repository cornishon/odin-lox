package olox

Token :: struct {
	kind: Token_Kind,
	text: string,
	line: u32,
	offset: int,
}

Token_Kind :: enum {
	// Single-character tokens.
	Left_Paren,
	Right_Paren,
	Left_Brace,
	Right_Brace,
	Left_Bracket,
	Right_Bracket,
	Comma,
	Dot,
	Minus,
	Plus,
	Semicolon,
	Slash,
	Star,

	// One or two character tokens.
	Bang,
	Bang_Equal,
	Equal,
	Equal_Equal,
	Greater,
	Greater_Equal,
	Less,
	Less_Equal,

	// Literals.
	Identifier,
	String,
	Number,
	Rune,

	// Keywords.
	And,
	Class,
	Else,
	False,
	For,
	Fun,
	If,
	Nil,
	Or,
	Print,
	Return,
	Super,
	This,
	True,
	Var,
	While,

	// errors/eof
	Unterminated,
	Invalid,
	Eof,
}
