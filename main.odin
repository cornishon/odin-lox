package olox

import "core:bufio"
import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer {
			for _, leak in track.allocation_map {
				fmt.printf("%v leaked %m\n", leak.location, leak.size)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	stdout := os.to_stream(os.stdout)
	vm_init(stdout); defer vm_destroy()

	s := bufio.scanner_init(&{}, os.to_stream(os.stdin))
	defer bufio.scanner_destroy(s)
	for bufio.scanner_scan(s) {
		vm_interpret(bufio.scanner_text(s))
	}
}
