package olox

import "core:fmt"

disassemble :: proc(ch: ^Chunk, name: string) {
	fmt.printfln("== %s ==", name)
	for offset, line := 0, u32(0); offset < len(ch.code); {
		offset, line = disassemble_instruction(ch, offset, line)
	}
}

disassemble_instruction :: proc(
	ch: ^Chunk,
	offset: int,
	prev_line: u32,
) -> (
	new_offset: int,
	new_line: u32,
) {
	fmt.printf("%04d ", offset)
	new_line = chunk_get_line(ch, offset)
	if prev_line == new_line {
		fmt.print("   | ")
	} else {
		fmt.printf("% 4d ", new_line)
	}

	op := Opcode(ch.code[offset])
	switch op {
	case .NIL,
	     .FALSE,
	     .TRUE,
	     .POP,
	     .RETURN,
	     .EQUAL,
	     .LESS,
	     .GREATER,
	     .ADD,
	     .SUB,
	     .MUL,
	     .DIV,
	     .NOT,
	     .NEGATE,
	     .PRINT:
		return simple_instruction(op, offset), new_line

	case .CONST, .DEF_GLOBAL, .GET_GLOBAL, .SET_GLOBAL:
		return constant_instruction(ch, op, offset), new_line

	case .GET_LOCAL, .SET_LOCAL:
		return byte_instruction(ch, op, offset), new_line

	case .LOOP, .JUMP, .JUMP_IF_NOT:
		return jump_instruction(ch, op, offset), new_line
	}

	fmt.printfln("Unknown opcode %d", op)
	return offset + 1, new_line
}

simple_instruction :: proc(op: Opcode, offset: int) -> int {
	fmt.printfln("%s", op)
	return offset + 1
}

constant_instruction :: proc(ch: ^Chunk, op: Opcode, offset: int) -> int {
	idx := ch.code[offset + 1]
	value := ch.consts[idx]
	fmt.printfln("%-16s % 4d %v", op, idx, value)
	return offset + 2
}

jump_instruction :: proc(ch: ^Chunk, op: Opcode, offset: int) -> int {
	jump := int(ch.code[offset + 1]) << 8
	jump |= int(ch.code[offset + 2])
	sign := -1 if op == .LOOP else 1
	fmt.printfln("%-16s % 4d -> %d", op, offset, offset + 3 + sign * jump)
	return offset + 3
}

byte_instruction :: proc(ch: ^Chunk, op: Opcode, offset: int) -> int {
	idx := ch.code[offset + 1]
	fmt.printfln("%-16s % 4d", op, idx)
	return offset + 2
}
