package olox

// key == nil && value == nil: EMPTY
// key == nil && value != nil: TOMBSTONE
Entry :: struct {
	key: ^String,
	value: Value,
}

Table :: struct {
	entries: []Entry,
	used: int,
}

table_destroy :: proc(table: ^Table) {
	delete(table.entries, lox_allocator())
	table^ = {}
}

table_set :: proc(table: ^Table, key: ^String, value: Value) -> (is_new: bool) {
	if table.used + 1 > len(table.entries) * 3 / 4 {
		capacity := len(table.entries) == 0 ? 8 : len(table.entries) * 2
		_table_grow(table, capacity)
	}

	entry := _find_slot(table.entries, key)
	is_new = entry.key == nil
	if is_new && entry.value == nil {
		table.used += 1
	}
	entry.key = key
	entry.value = value
	return
}

table_get :: proc(table: ^Table, key: ^String) -> (value: Value, ok: bool) #optional_ok {
	if len(table.entries) == 0 {return}
	entry := _find_slot(table.entries, key)
	if entry.key == nil {return}
	return entry.value, true
}

table_remove :: proc(table: ^Table, key: ^String) -> (existed: bool) {
	if len(table.entries) == 0 {return}
	entry := _find_slot(table.entries, key)
	if entry.key == nil {return}
	entry.key = nil
	entry.value = true
	return true
}

table_add_all :: proc(source: Table, dest: ^Table) {
	for e in source.entries {
		if e.key != nil {
			table_set(dest, e.key, e.value)
		}
	}
}

table_find_string :: proc(
	table: ^Table,
	str: string,
	hash: u32,
) -> (
	interned: ^String,
	found: bool,
) #optional_ok {
	if table.used == 0 {return}
	mask := len(table.entries) - 1

	for i := int(hash) & mask;; i = (i + 1) & mask {
		entry := &table.entries[i]
		if entry.key == nil {
			if entry.value == nil {return} 	// stop if we find an empty non-tombstone entry
		} else if entry.key.hash == hash && entry.key.data == str {
			return entry.key, true
		}
	}
}

table_remove_white :: proc(table: ^Table) {
	for e in table.entries {
		if e.key != nil && !e.key.is_marked {
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

_find_slot :: proc(entries: []Entry, key: ^String) -> ^Entry {
	mask := len(entries) - 1
	tombstone: Maybe(^Entry)
	for i := int(key.hash) & mask;; i = (i + 1) & mask {
		entry := &entries[i]
		if entry.key == nil {
			if entry.value == nil {
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

_table_grow :: proc(table: ^Table, new_capacity: int) {
	new_entries := make([]Entry, new_capacity, lox_allocator())

	table.used = 0
	for e in table.entries {
		if e.key != nil {
			_find_slot(new_entries, e.key)^ = e
			table.used += 1
		}
	}

	delete(table.entries, lox_allocator())
	table.entries = new_entries
}
