/**
 * vargs 0.4.2
 * https://github.com/nedpals/vargs
 * 
 * (c) 2019 Ned Palacios and its contributors.
 */
import vargs

const (
    test_arr = ['hello', '-f', 'bar', '--foo', 'baz', '--lol=yey', '-t=test', '123', '-n', '--foo', 'bal']
)

fn test_parse() {
    a := vargs.parse(test_arr, 0)

    assert a.command == 'hello'
    assert a.options['f'] == 'bar'
    assert a.options['foo'] == 'baz,bal'
    assert a.options['lol'] == 'yey'
    assert a.options['t'] == 'test'
    assert a.options['n'] == ''
    assert a.unknown[0] == '123'
}

fn test_str() {
    a := vargs.parse(test_arr, 0)

    assert a.str() == '\{ command: "hello", options: { "f" => "bar" "foo" => "baz,bal" "lol" => "yey" "t" => "test" }, unknown: ["123"] \}'
}

fn test_array_option() {
    a := vargs.parse(test_arr, 0)
    option_arr := a.array_option('foo')

    assert option_arr.len == 2
    assert option_arr[0] == 'baz'
    assert option_arr[1] == 'bal'
}