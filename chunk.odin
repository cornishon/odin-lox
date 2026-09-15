package olox

Chunk :: struct {
	code: [dynamic]u8,
	consts: [dynamic]Value,
	lines: [dynamic]Line,
}

// Run-length encoded
Line :: struct {
	lnum: u32,
	count: u32,
}

chunk_init :: proc(ch: ^Chunk) -> ^Chunk {
	allocator := lox_allocator()
	ch.code.allocator = allocator
	ch.consts.allocator = allocator
	ch.lines.allocator = allocator
	return ch
}

chunk_deinit :: proc(ch: ^Chunk) {
	delete(ch.code)
	delete(ch.consts)
	delete(ch.lines)
	ch^ = {}
}

chunk_add_const :: proc(ch: ^Chunk, value: Value) -> int {
	push(value); defer pop_()
	append(&ch.consts, value)
	return len(ch.consts) - 1
}

Write_Arg :: union {
	Opcode,
	u8,
	u16,
}

chunk_write :: proc(ch: ^Chunk, line: u32, bs: ..Write_Arg) {
	n: int
	for b in bs {
		switch v in b {
		case Opcode:
			n += append(&ch.code, u8(v))
		case u8:
			n += append(&ch.code, v)
		case u16:
			n += append(&ch.code, u8(v >> 8), u8(v))
		}
	}
	if len(ch.lines) > 0 {
		l := &ch.lines[len(ch.lines) - 1]
		if l.lnum == line {
			l.count += u32(n)
			return
		}
	}
	append(&ch.lines, Line{lnum = line, count = u32(n)})
}

chunk_get_line :: proc(ch: ^Chunk, idx: int) -> u32 {
	assert(idx < len(ch.code))
	i: int
	for l in ch.lines {
		i += int(l.count)
		if i > idx {
			return l.lnum
		}
	}
	return 0
}
