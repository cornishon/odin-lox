package olox

import "base:runtime"
_ :: runtime

Entry :: struct {
	key: ^String,
	value: Value,
}

Table :: struct {
	entries: []Entry,
	used: int,
}

@(private = "file")
EMPTY :: (^String)(uintptr(0))
@(private = "file")
TOMBSTONE :: (^String)(uintptr(1))

table_init :: proc "contextless" (table: ^Table) {
	// nothing
}

table_destroy :: proc(table: ^Table) {
	delete(table.entries, lox_allocator())
	table^ = {}
}

table_set :: proc "contextless" (table: ^Table, key: ^String, value: Value) -> (is_new: bool) {
	if table.used + 1 > len(table.entries) * 3 / 4 {
		capacity := len(table.entries) == 0 ? 8 : len(table.entries) * 2
		_table_grow(table, capacity)
	}
	entry := _find_slot(table.entries, key)
	is_new = entry.key <= TOMBSTONE
	table.used += int(entry.key == EMPTY)
	entry.key = key
	entry.value = value
	return
}

table_get :: proc "contextless" (
	table: ^Table,
	key: ^String,
) -> (
	value: Value,
	ok: bool,
) #optional_ok {
	if len(table.entries) == 0 {return}
	entry := _find_slot(table.entries, key)
	if entry.key <= TOMBSTONE {return}
	return entry.value, true
}

table_remove :: proc "contextless" (table: ^Table, key: ^String) -> (existed: bool) {
	if len(table.entries) == 0 {return}
	entry := _find_slot(table.entries, key)
	if entry.key <= TOMBSTONE {return}
	entry.key = TOMBSTONE
	return true
}

table_add_all :: proc "contextless" (source: Table, dest: ^Table) {
	for e in source.entries {
		if e.key > TOMBSTONE {
			table_set(dest, e.key, e.value)
		}
	}
}

// check if s + t is already in the table
table_find_string :: proc "contextless" (
	table: ^Table,
	hash: u32,
	s: string,
	t: string = "",
) -> (
	interned: ^String,
	found: bool,
) #optional_ok {
	if table.used == 0 {return}
	mask := len(table.entries) - 1
	length := len(s) + len(t)

	#no_bounds_check for i := int(hash) & mask;; i = (i + 1) & mask {
		ek := table.entries[i].key
		if ek == EMPTY {return} 	// stop if we find an empty non-tombstone entry
		if ek > TOMBSTONE && ek.hash == hash && ek.len == length {
			if string_text(ek)[:len(s)] == s && string_text(ek)[len(s):][:len(t)] == t {
				return ek, true
			}
		}
	}
}

table_remove_white :: proc "contextless" (table: ^Table) {
	for e in table.entries {
		if e.key > TOMBSTONE && !e.key.is_marked {
			table_remove(table, e.key)
		}
	}
}

mark_table :: proc(t: ^Table) {
	for e in t.entries {
		mark_object(e.key)
		mark_value(e.value)
	}
}

_find_slot :: proc "contextless" (entries: []Entry, key: ^String) -> ^Entry {
	mask := len(entries) - 1
	tombstone: Maybe(^Entry)
	#no_bounds_check for i := int(key.hash) & mask;; i = (i + 1) & mask {
		entry := &entries[i]
		if entry.key <= TOMBSTONE {
			if entry.key == EMPTY {
				// on empty entry return the first tombstone we've seen
				// so table_set can overwrite it
				return tombstone.? or_else entry
			} else {
				// save the first tombstone we've seen
				if tombstone == nil {
					tombstone = entry
				}
			}
		} else if entry.key == key {
			return entry
		}
	}
}

_table_grow :: proc "contextless" (table: ^Table, new_capacity: int) {
	context = vm.ctx
	new_entries := make([]Entry, new_capacity)

	table.used = 0
	for e in table.entries {
		if e.key > TOMBSTONE {
			_find_slot(new_entries, e.key)^ = e
			table.used += 1
		}
	}

	delete(table.entries)
	table.entries = new_entries
}
