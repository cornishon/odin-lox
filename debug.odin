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

	switch op := Opcode(ch.code[offset]); op {
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
	     .CLOSE_UPVALUE,
	     .INHERIT,
	     .SET_ARRAY,
	     .GET_ARRAY,
	     .PRINT:
		new_offset = simple_instruction(op, offset)

	case .CONST,
	     .DEF_GLOBAL,
	     .GET_GLOBAL,
	     .SET_GLOBAL,
	     .CLASS,
	     .GET_PROPERTY,
	     .SET_PROPERTY,
	     .GET_SUPER,
	     .METHOD:
		new_offset = constant_instruction(ch, op, offset)

	case .GET_LOCAL, .SET_LOCAL, .GET_UPVALUE, .SET_UPVALUE, .CALL:
		new_offset = byte_instruction(ch, op, offset)

	case .LOOP, .JUMP, .JUMP_IF_NOT:
		new_offset = jump_instruction(ch, op, offset)

	case .CLOSURE:
		idx := ch.code[offset + 1]
		fmt.printfln("%-16s % 4d", op, idx)

		fn := ch.consts[idx].(^Object).variant.(^Function)
		for i in 0 ..< fn.upvalue_count {
			is_local := bool(ch.code[2 * i])
			index := ch.code[2 * i + 1]
			fmt.printfln(
				"%04d    |                     %s %d",
				offset - 2,
				is_local ? "local" : "upvalue",
				index,
			)
		}
		new_offset = offset + 2 + 2 * fn.upvalue_count

	case .INVOKE, .SUPER_INVOKE:
		new_offset = invoke_instruction(ch, op, offset)

	case .ARRAY:
		n := ch.code[offset + 1]
		fmt.printfln("%-16s % 4d", op, n)
		new_offset = offset + 2

	case:
		fmt.printfln("Unknown opcode %d", op)
		new_offset = offset + 1
	}

	return
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

invoke_instruction :: proc(ch: ^Chunk, op: Opcode, offset: int) -> int {
	idx := ch.code[offset + 1]
	argc := ch.code[offset + 2]
	name := ch.consts[idx]
	fmt.printfln("%-16s (%d args) % 4d %s", op, argc, idx, name)
	return offset + 2
}
