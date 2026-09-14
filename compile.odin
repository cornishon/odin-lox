package olox

import "core:fmt"
import "core:slice"
import "core:strconv"

Precedence :: enum {
	None,
	Assignment, // =
	Or, // or
	And, // and
	Equality, // == !=
	Comparison, // < > <= >=
	Term, // + -
	Factor, // * /
	Unary, // ! -
	Call, // . ()
	Primary,
}

Parse_Proc :: #type proc(can_assign: bool)

Parse_Rule :: struct {
	prefix: Parse_Proc,
	infix: Parse_Proc,
	precedence: Precedence,
}

@(private = "file")
Local :: struct {
	name: Token,
	depth: int,
	is_captured: bool,
}

@(private = "file")
Upvalue :: struct {
	index: u8,
	is_local: bool,
}

Function_Kind :: enum {
	Function,
	Script,
}

Compiler :: struct {
	enclosing: ^Compiler,
	function: ^Function,
	kind: Function_Kind,
	locals: [dynamic; 256]Local,
	upvalues: [dynamic; 256]Upvalue,
	scope_depth: int,
	identifiers: Table,
}

Parser :: struct {
	current: Token,
	previous: Token,
	had_error: bool,
	panic_mode: bool,
}

@(thread_local)
scanner: Scanner
@(thread_local)
parser: Parser
@(thread_local)
current: ^Compiler

compile :: proc(source: string) -> (^Function, bool) {
	scanner = scanner_init(source)
	parser = {}
	compiler_init(&{}, .Script)

	advance()
	for !match(.Eof) {
		declaration()
	}

	return compiler_end(), !parser.had_error
}

current_chunk :: proc() -> ^Chunk {
	return &current.function.chunk
}

error_at :: proc(token: Token, message: string) {
	if parser.panic_mode {return}
	parser.panic_mode = true
	fmt.eprintf("[line %d] Error", token.line)
	if token.kind == .Eof {
		fmt.eprintf(" at end")
	} else if token.kind == .Error {
		// Nothing
	} else {
		fmt.eprintf(" at '%s'", token.text)
	}
	fmt.eprintf(": %s\n", message)
	parser.had_error = true
}

error :: proc(message: string) {
	error_at(parser.previous, message)
}

error_at_current :: proc(message: string) {
	error_at(parser.current, message)
}

advance :: proc() {
	parser.previous = parser.current
	for {
		parser.current = scan_token(&scanner)
		if parser.current.kind != .Error {break}
		error_at_current(parser.current.text)
	}
}

consume :: proc(kind: Token_Kind, message: string) {
	if parser.current.kind == kind {
		advance()
	} else {
		error_at_current(message)
	}
}

check :: proc(kind: Token_Kind) -> bool {
	return parser.current.kind == kind
}

match :: proc(kind: Token_Kind) -> bool {
	if !check(kind) {return false}
	advance()
	return true
}

emit :: proc(bytes: ..Write_Arg) {
	chunk_write(current_chunk(), parser.previous.line, ..bytes)
}

emit_loop :: proc(start: int) {
	emit(.LOOP)
	offset := len(current_chunk().code) - start + 2
	if offset > int(max(u16)) {
		error("Loop body too large.")
	}
	emit(cast(u16)(offset))
}

emit_jump :: proc(op: Opcode) -> int {
	emit(op, u16(0xffff)) // to be patched later
	return len(current_chunk().code) - 2
}

make_constant :: proc(value: Value) -> u8 {
	i := chunk_add_const(current_chunk(), value)
	if i > int(max(u8)) {
		error("Too many constants.")
		// return 0
	}
	return u8(i)
}

emit_constant :: proc(value: Value) {
	emit(.CONST, make_constant(value))
}

patch_jump :: proc(offset: int) {
	jump := len(current_chunk().code) - offset - 2
	if jump > int(max(u16)) {
		error("Too much code to jump over.")
	}
	current_chunk().code[offset] = u8(jump >> 8)
	current_chunk().code[offset + 1] = u8(jump)
}

compiler_init :: proc(compiler: ^Compiler, fun_kind: Function_Kind) {
	compiler.enclosing = current
	compiler.function = function_new(fun_kind == .Script ? "<script>" : parser.previous.text)
	compiler.kind = fun_kind
	current = compiler
	append(&current.locals, Local{})
}

compiler_end :: proc() -> ^Function {
	emit(.NIL, .RETURN)
	function := current.function
	table_destroy(&current.identifiers)
	current = current.enclosing
	when ODIN_DEBUG {
		disassemble(&function.chunk, function.name.data)
	}
	return function
}

begin_scope :: proc() {
	current.scope_depth += 1
}

end_scope :: proc() {
	current.scope_depth -= 1
	for i := len(current.locals) - 1; i >= 0; i -= 1 {
		local := current.locals[i]
		if local.depth <= current.scope_depth {break}
		emit(local.is_captured ? .CLOSE_UPVALUE : .POP)
		pop(&current.locals)
	}
}

identifier_constant :: proc(token: Token) -> u8 {
	name := string_copy(token.text)
	if v, ok := table_get(&current.identifiers, name); ok {
		return u8(v.(f64))
	}
	idx := make_constant(name)
	table_set(&current.identifiers, name, f64(idx))
	return idx
}

resolve_upvalue :: proc(compiler: ^Compiler, name: Token) -> (idx: u8, ok: bool) {
	if compiler.enclosing == nil {return}
	if local, l_ok := resolve_local(compiler.enclosing, name); l_ok {
		compiler.enclosing.locals[local].is_captured = true
		return add_upvalue(compiler, local, true), true
	}
	if upvalue, u_ok := resolve_upvalue(compiler.enclosing, name); u_ok {
		return add_upvalue(compiler, upvalue, false), true
	}
	return
}

add_upvalue :: proc(compiler: ^Compiler, index: u8, is_local: bool) -> u8 {
	for uv, i in compiler.upvalues {
		if uv.index == index && uv.is_local == is_local {
			return u8(i)
		}
	}
	if append(&compiler.upvalues, Upvalue{index, is_local}) == 0 {
		error("Too many closure variables in function.")
		return 0
	}
	defer compiler.function.upvalue_count += 1
	return u8(compiler.function.upvalue_count)
}

resolve_local :: proc(compiler: ^Compiler, token: Token) -> (idx: u8, ok: bool) {
	#reverse for local, i in compiler.locals {
		if token.text == local.name.text {
			if local.depth == -1 {
				error("Can't read local variable in its own initializer.")
			}
			return u8(i), true
		}
	}
	return
}

add_local :: proc(name: Token) {
	if append(&current.locals, Local{name = name, depth = -1}) == 0 {
		error("Too many local variables in function.")
	}
}

declare_variable :: proc() {
	if current.scope_depth == 0 {return}
	name := parser.previous
	#reverse for local in current.locals {
		if local.depth != -1 && local.depth < current.scope_depth {
			break
		}
		if name.text == local.name.text {
			error("Already a variable with this name in current scope.")
		}
	}
	add_local(name)
}

parse_variable :: proc(error_message: string) -> u8 {
	consume(.Identifier, error_message)
	declare_variable()
	if current.scope_depth > 0 {return 0}
	return identifier_constant(parser.previous)
}

mark_initialized :: proc() {
	if current.scope_depth == 0 {return}
	slice.last_ptr(current.locals[:]).depth = current.scope_depth
}

define_variable :: proc(global: u8) {
	if current.scope_depth > 0 {
		mark_initialized()
	} else {
		emit(.DEF_GLOBAL, global)
	}
}

argument_list :: proc() -> (arg_count: u8) {
	for {
		if check(.Right_Paren) {break}
		expression()
		if arg_count == 255 {
			error("Cant' have more than 255 arguments.")
		}
		arg_count += 1
		if !match(.Comma) {break}
	}
	consume(.Right_Paren, "Expected ')' after arguments.")
	return
}

and :: proc(can_assign: bool) {
	end_jump := emit_jump(.JUMP_IF_NOT)
	emit(.POP)
	parse_precedence(.And)
	patch_jump(end_jump)
}

or :: proc(can_assign: bool) {
	else_jump := emit_jump(.JUMP_IF_NOT)
	end_jump := emit_jump(.JUMP)
	patch_jump(else_jump)
	emit(.POP)
	parse_precedence(.Or)
	patch_jump(end_jump)
}

binary :: proc(can_assign: bool) {
	op_kind := parser.previous.kind
	rule := rules[op_kind]
	parse_precedence(rule.precedence + auto_cast 1)
	// odinfmt: disable
	#partial switch op_kind {
	case .Bang_Equal:    emit(.EQUAL, .NOT)
	case .Equal_Equal:   emit(.EQUAL)
	case .Greater:       emit(.GREATER)
	case .Greater_Equal: emit(.LESS, .NOT)
	case .Less:          emit(.LESS)
	case .Less_Equal:    emit(.GREATER, .NOT)
	case .Plus:          emit(.ADD)
	case .Minus:         emit(.SUB)
	case .Star:          emit(.MUL)
	case .Slash:         emit(.DIV)
	case: fmt.panicf("Unhandled binary token: %v", op_kind)
	}
	// odinfmt: enable
}

call :: proc(can_assign: bool) {
	arg_count := argument_list()
	emit(.CALL, arg_count)
}

grouping :: proc(can_assign: bool) {
	expression()
	consume(.Right_Paren, "Expected ')' after expression.")
}

literal :: proc(can_assign: bool) {
	// odinfmt: disable
	#partial switch k := parser.previous.kind; k {
	case .False: emit(.FALSE)
	case .True:  emit(.TRUE)
	case .Nil:   emit(.NIL)
	case: fmt.panicf("Unhandled literal token: %v", k)
	}
	// odinfmt: enable
}

number :: proc(can_assign: bool) {
	value, ok := strconv.parse_f64(parser.previous.text)
	if !ok {
		error("Invalid number literal")
	}
	emit_constant(value)
}

string_ :: proc(can_assign: bool) {
	s := parser.previous.text
	emit_constant(string_copy(s[1:len(s) - 1]))
}

variable :: proc(can_assign: bool) {
	named_variable(parser.previous, can_assign)
}

named_variable :: proc(name: Token, can_assign: bool) {
	get, set: Opcode
	arg, ok := resolve_local(current, name)
	if ok {
		get = .GET_LOCAL
		set = .SET_LOCAL
	} else if arg, ok = resolve_upvalue(current, name); ok {
		get = .GET_UPVALUE
		set = .SET_UPVALUE
	} else {
		arg = identifier_constant(name)
		get = .GET_GLOBAL
		set = .SET_GLOBAL
	}
	if can_assign && match(.Equal) {
		expression()
		emit(set, arg)
	} else {
		emit(get, arg)
	}
}

unary :: proc(can_assign: bool) {
	op_kind := parser.previous.kind
	parse_precedence(.Unary)
	// odinfmt: disable
	#partial switch op_kind {
	case .Bang:  emit(.NOT)
	case .Minus: emit(.NEGATE)
	case: fmt.panicf("Unhandled unary token: %v", op_kind)
	}
	// odinfmt: enable
}
// odinfmt: disable
@(rodata)
rules := #partial [Token_Kind]Parse_Rule {
	.Nil           = { literal,  nil,    .None       },
	.True          = { literal,  nil,    .None       },
	.False         = { literal,  nil,    .None       },
	.Bang          = { unary,    nil,    .None       },
	.Identifier    = { variable, nil,    .None       },
	.String        = { string_,  nil,    .None       },
	.Number        = { number,   nil,    .None       },
	.Left_Paren    = { grouping, call,   .Call       },
	.Minus         = { unary,    binary, .Term       },
	.Plus          = { nil,      binary, .Term       },
	.Slash         = { nil,      binary, .Factor     },
	.Star          = { nil,      binary, .Factor     },
	.Bang_Equal    = { nil,      binary, .Equality   },
	.Equal_Equal   = { nil,      binary, .Equality   },
	.Greater       = { nil,      binary, .Comparison },
	.Greater_Equal = { nil,      binary, .Comparison },
	.Less          = { nil,      binary, .Comparison },
	.Less_Equal    = { nil,      binary, .Comparison },
	.And           = { nil,      and,    .And        },
	.Or            = { nil,      or,     .Or         },
}
// odinfmt: enable

parse_precedence :: proc(precedence: Precedence) {
	advance()
	prefix_rule := rules[parser.previous.kind].prefix
	if prefix_rule == nil {
		error("Expected expression.")
		return
	}

	can_assign := precedence <= .Assignment
	prefix_rule(can_assign)

	for precedence <= rules[parser.current.kind].precedence {
		advance()
		infix_rule := rules[parser.previous.kind].infix
		infix_rule(can_assign)
	}

	if can_assign && match(.Equal) {
		error("Invalid assignment target.")
	}
}

expression :: proc() {
	parse_precedence(.Assignment)
}

block :: proc() {
	for !check(.Right_Brace) && !check(.Eof) {
		declaration()
	}
	consume(.Right_Brace, "Expected '}' after block.")
}

function :: proc(kind: Function_Kind) {
	compiler: Compiler
	compiler_init(&compiler, kind)
	begin_scope() // no need to end_scope since we end the compiler after finishing function body

	consume(.Left_Paren, "Expected '(' after function name.")
	for {
		if check(.Right_Paren) {break}
		current.function.arity += 1
		if current.function.arity > 255 {
			error_at_current("Can't have mre than 255 parameters.")
		}
		id := parse_variable("Expected parameter name.")
		define_variable(id)
		if !match(.Comma) {break}
	}
	consume(.Right_Paren, "Expected ')' after parameters.")

	consume(.Left_Brace, "Expected '{' before function body.")
	block()

	fn := compiler_end()
	emit(.CLOSURE, make_constant(fn))
	for uv in compiler.upvalues {
		emit(u8(uv.is_local), uv.index)
	}
}

fun_declaration :: proc() {
	id := parse_variable("Expect function name.")
	mark_initialized()
	function(.Function)
	define_variable(id)
}

var_declaration :: proc() {
	global := parse_variable("Expected variable name.")
	if match(.Equal) {
		expression()
	} else {
		emit(.NIL)
	}
	consume(.Semicolon, "Expected ';' after variable declaration.")
	define_variable(global)
}

expression_statement :: proc() {
	expression()
	consume(.Semicolon, "Expected ';' after expression.")
	emit(.POP)
}

for_statement :: proc() {
	begin_scope()
	defer end_scope()
	consume(.Left_Paren, "Expected '(' after 'for'.")

	if match(.Semicolon) {
		// no initializer
	} else if match(.Var) {
		var_declaration()
	} else {
		expression_statement()
	}

	loop_start := len(current_chunk().code)
	exit_jump := -1
	if !match(.Semicolon) {
		expression()
		consume(.Semicolon, "Expected ';' after loop condition.")
		exit_jump = emit_jump(.JUMP_IF_NOT)
		emit(.POP)
	}

	if !match(.Right_Paren) {
		body_jump := emit_jump(.JUMP)
		inc_start := len(current_chunk().code)

		expression()
		emit(.POP)
		consume(.Right_Paren, "Expected ')' after for clauses.")

		emit_loop(loop_start)
		loop_start = inc_start
		patch_jump(body_jump)
	}

	statement()
	emit_loop(loop_start)

	if exit_jump != -1 {
		patch_jump(exit_jump)
		emit(.POP)
	}
}

if_statement :: proc() {
	consume(.Left_Paren, "Expected '(' after 'if'.")
	expression()
	consume(.Right_Paren, "Expected ')' after condition.")

	then_jump := emit_jump(.JUMP_IF_NOT)
	emit(.POP)
	statement()

	else_jump := emit_jump(.JUMP)
	patch_jump(then_jump)
	emit(.POP)

	if match(.Else) {
		statement()
	}
	patch_jump(else_jump)
}

print_statement :: proc() {
	expression()
	consume(.Semicolon, "Expected ';' after value.")
	emit(.PRINT)
}

return_statement :: proc() {
	if current.kind == .Script {
		error("Can't return from top-level code.")
	}
	if check(.Semicolon) {
		emit(.NIL)
	} else {
		expression()
	}
	consume(.Semicolon, "Expected ';' after return value.")
	emit(.RETURN)
}

while_statement :: proc() {
	loop_start := len(current_chunk().code)
	consume(.Left_Paren, "Expected '(' after 'while'")
	expression()
	consume(.Right_Paren, "Expected ')' after condition")

	exit_jump := emit_jump(.JUMP_IF_NOT)
	emit(.POP)
	statement()

	emit_loop(loop_start)
	patch_jump(exit_jump)
	emit(.POP)
}

synchronize :: proc() {
	parser.panic_mode = false
	for parser.current.kind != .Eof {
		if parser.previous.kind == .Semicolon {return}
		#partial switch parser.current.kind {
		case .Class, .Fun, .Var, .For, .If, .While, .Print, .Return:
			return
		case:
			advance()
		}
	}
}

declaration :: proc() {
	switch {
	case match(.Fun):
		fun_declaration()
	case match(.Var):
		var_declaration()
	case:
		statement()
	}

	if parser.panic_mode {
		synchronize()
	}
}

statement :: proc() {
	switch {
	case match(.Print):
		print_statement()
	case match(.For):
		for_statement()
	case match(.If):
		if_statement()
	case match(.Return):
		return_statement()
	case match(.While):
		while_statement()
	case match(.Left_Brace):
		begin_scope()
		block()
		end_scope()
	case:
		expression_statement()
	}
}
