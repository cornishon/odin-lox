package olox

import "core:strings"
import "core:testing"

expect_output :: proc(t: ^testing.T, expected: string, source: string) {
	b: strings.Builder
	defer strings.builder_destroy(&b)
	vm_init(strings.to_writer(&b))
	defer vm_destroy()
	testing.expect(t, vm_interpret(source))
	actual := strings.to_string(b)
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
