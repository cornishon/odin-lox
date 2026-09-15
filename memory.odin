package olox

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:reflect"

// DEBUG_LOG_GC needs those
_ :: fmt
_ :: reflect

HEAP_GROW_FACTOR :: 2

lox_allocator :: proc() -> mem.Allocator {
	return {
		procedure = _lox_allocator_proc,
	}
}

collect_garbage :: proc() {
	when DEBUG_LOG_GC {
		fmt.print("\n-- gc begin\n")
		before := vm.bytes_allocated
	}
	mark_roots()
	trace_references()
	table_remove_white(&vm.strings)
	sweep()
	vm.next_gc = vm.bytes_allocated * HEAP_GROW_FACTOR
	when DEBUG_LOG_GC {
		fmt.printfln(
			"-- gc end\n   collected %d bytes (from %d to %d); next at %d\n",
			before - vm.bytes_allocated,
			before,
			vm.bytes_allocated,
			vm.next_gc,
		)
	}
}

mark_roots :: proc() {
	stack_size := mem.ptr_sub(&vm.stack_top[0], &vm.stack[0]) + 1
	for slot in vm.stack[:stack_size] {
		mark_value(slot)
	}
	for frame in vm.frames[:vm.frame_count] {
		mark_object(frame.closure)
	}
	for uv := vm.open_upvalues; uv != nil; uv = uv.next_open {
		mark_object(uv)
	}
	mark_table(&vm.globals)
	mark_compiler_roots()
	mark_object(vm.init_string)
}

trace_references :: proc() {
	for obj in pop_safe(&vm.gray_stack) {
		blacken_object(obj)
	}
}

sweep :: proc() {
	prev: ^Object
	for obj := vm.objects; obj != nil; {
		if obj.is_marked {
			obj.is_marked = false
			prev = obj
			obj = obj.next_obj
		} else {
			unreached := obj
			obj = obj.next_obj
			if prev != nil {
				prev.next_obj = obj
			} else {
				vm.objects = obj
			}
			obj_destroy(unreached)
		}
	}
}

blacken_object :: proc(obj: ^Object) {
	when DEBUG_LOG_GC {fmt.printfln("%p blacken %v", obj, obj)}
	switch v in obj.variant {
	case ^Function:
		mark_object(v.name)
		for c in v.chunk.consts[:] {
			mark_value(c)
		}
	case ^Closure:
		mark_object(v.function)
		for uv in v.upvalues {
			mark_object(uv)
		}
	case ^Class:
		mark_object(v.name)
		mark_table(&v.methods)
	case ^Upvalue:
		mark_value(v.closed)
	case ^Instance:
		mark_object(v.class)
		mark_table(&v.fields)
	case ^Bound_Method:
		mark_value(v.receiver)
		mark_object(v.method)
	case ^String, ^Native:
	}
}

mark_value :: proc(value: Value) {
	if obj, ok := value.(^Object); ok {
		mark_object(obj)
	}
}

mark_object :: proc(o: ^Object) {
	if o == nil {return}
	if o.is_marked {return}
	when DEBUG_LOG_GC {fmt.printfln("%p mark %v", o, o)}
	o.is_marked = true
	switch v in o.variant {
	case ^Function, ^Closure, ^Upvalue, ^Class, ^Instance, ^Bound_Method:
		append(&vm.gray_stack, o)
	case ^String, ^Native:
	}
}

_lox_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	new_size, alignment: int,
	pointer: rawptr,
	old_size: int,
	location: runtime.Source_Code_Location = #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	vm.bytes_allocated += new_size - old_size
	// fmt.printfln("== %v: %v -> %v, now at: %v ==", mode, old_size, new_size, vm.bytes_allocated)

	if new_size > old_size {
		when DEBUG_STRESS_GC {
			collect_garbage()
		} else {
			if vm.bytes_allocated > vm.next_gc {
				collect_garbage()
			}
		}
	}

	a := &vm.backing_allocator
	return a.procedure(a.data, mode, new_size, alignment, pointer, old_size, location)
}
