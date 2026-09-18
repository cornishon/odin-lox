#+test
package olox

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_examples :: proc(t: ^testing.T) {
	temp := context.temp_allocator
	defer free_all(temp)
	loxfiles, err := filepath.glob(#directory + "examples/*.lox", temp)
	testing.expect(t, err == nil, "Failed to open examples folder")
	errors := t.error_count
	for path in loxfiles {
		run_file(t, path, temp)
		if t.error_count > errors {
			log.error(path)
		}
		errors += t.error_count
	}
}

run_file :: proc(t: ^testing.T, loxpath: string, temp := context.temp_allocator) {
	outpath := fmt.tprintf("%s/%s.%s", filepath.dir(loxpath), filepath.stem(loxpath), "out")
	errpath := fmt.tprintf("%s/%s.%s", filepath.dir(loxpath), filepath.stem(loxpath), "err")
	source, stdout, stderr: []u8
	err: os.Error
	source, err = os.read_entire_file(loxpath, temp)
	if (err != nil) {log.errorf("%s: %s", loxpath, os.error_string(err))}
	stdout, err = os.read_entire_file(outpath, temp)
	if (err != nil) {log.errorf("%s: %s", outpath, os.error_string(err))}
	stderr, err = os.read_entire_file(errpath, temp)
	if (err != nil) {log.errorf("%s: %s", errpath, os.error_string(err))}
	if len(stderr) == 0 {
		log.info(loxpath)
		expect_output(t, string(stdout), string(source))
	}
}

expect_output :: proc(t: ^testing.T, expected: string, source: string) {
	b := strings.builder_init(&{})
	defer strings.builder_destroy(b)
	vm_init(strings.to_writer(b)); defer vm_destroy()
	testing.expect(t, vm_interpret(source))
	actual := strings.to_string(b^)
	testing.expect_value(t, actual, expected)
}

@(test)
local_variables :: proc(t: ^testing.T) {
	expect_output(
		t,
		"inner\nouter\n",
		`{
			var x = "outer";
			{
				var x = "inner";
				print x;
			}
			print x;
		}`,
	)
}

@(test)
loops :: proc(t: ^testing.T) {
	expect_output(t, "0\n1\n2\n3\n4\n", `for (var i = 0; i < 5; i = i + 1) print i;`)
	expect_output(t, "4\n3\n2\n1\n0\n", `var i = 4; while (i >= 0) {print i; i = i - 1;}`)
}
