package olox

import "core:mem"

// key == nil && value == nil: EMPTY
// key == nil && value != nil: TOMBSTONE
Entry :: struct {
	key: ^String,
	value: Value,
}

Table :: struct {
	entries: []Entry,
	used: int,
	allocator: mem.Allocator,
}

table_init :: proc(table: ^Table, allocator := context.allocator) -> ^Table {
	table.allocator = allocator
	return table
}

table_destroy :: proc(table: ^Table) {
	delete(table.entries, table.allocator)
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

table_find_string :: proc(
	table: ^Table,
	str: string,
	hash: u32,
) -> (
	interned: ^String,
	found: bool,
) #optional_ok {
	if table.used == 0 {return}
	capacity := len(table.entries)
	index := int(hash) % capacity
	for {
		entry := &table.entries[index]
		index = (index + 1) % capacity
		if entry.key == nil {
			if entry.value == nil {return} 	// stop if we find an empty non-tombstone entry
		} else if entry.key.hash == hash && entry.key.data == str {
			return entry.key, true
		}
	}
}

_find_slot :: proc(entries: []Entry, key: ^String) -> ^Entry {
	capacity := len(entries)
	index := int(key.hash) % capacity
	tombstone: Maybe(^Entry)
	for {
		entry := &entries[index]
		index = (index + 1) % capacity
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
	if table.allocator.procedure == nil {
		table.allocator = context.allocator
	}
	new_entries := make([]Entry, new_capacity, table.allocator)

	table.used = 0
	for e in table.entries {
		if e.key != nil {
			_find_slot(new_entries, e.key)^ = e
			table.used += 1
		}
	}

	delete(table.entries, table.allocator)
	table.entries = new_entries
}
