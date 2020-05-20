# V-JSONRPC
A basic JSON-RPC 2.0-compliant server written on V. V-JSONRPC 0.2 is now transfer protocol-independent meaning it is not tied to one protocol and it can now be used in other ways such as STDIN, TCP, UDP and more provided that the provided input is a string.

## Install
### VPM
```
v install nedpals.jsonrpc
```

### [vpkg](https://github.com/vpkg-project/vpkg)
```
vpkg get v-jsonrpc
```

## Example
This code example is taken from the [`stdin_example.v`](examples/stdin_example.v) which uses a standard input (STDIN) as the main source for calling procedures.

```v
fn emit_error(err_code int) Response {
    mut eres := Response{}
    eres.send_error(err_code)
    return eres
}

fn greet_person(ctx mut Context) string {
    name := jsonrpc.as_string(ctx.req.params)
    return 'Hello, $name'
}

fn main() {
    srv := jsonrpc.new()
    srv.register('greet', greet_person)

    for {
        line := os.get_line()
        res := srv.exec(line) or { 
            err_code := err.int()
            eres := emit_error(err_code)
            println(eres.gen_json())
            continue
        }

        println(res.gen_json())
    }
}
```

### Error Handling
V-JSONRPC includes basic error handling as well as a set of public constants for easy use.
```golang
pub const (
    PARSE_ERROR = -32700
    INVALID_REQUEST = -32600
    METHOD_NOT_FOUND = -32601
    INVALID_PARAMS = -32602
    INTERNAL_ERROR = -32693    
    SERVER_ERROR_START = -32099
    SERVER_ERROR_END = -32600
    SERVER_NOT_INITIALIZED = -32002
    UNKNOWN_ERROR_CODE = -32001
)
```

```v
//... Function context must be mutable. e.g fn proc_name(ctx mut jsonrpc.Context)
    ctx.res.send_error(jsonrpc.INVALID_REQUEST)
    return 'error!'
//...
```

```json
{
    "jsonrpc":"2.0",
    "id":0,
    "error":{
        "code":-32600,
        "message":"Invalid request.",
        "data":""
    }
}
```

## Parameter/Payload Handling
Due to the limitations of the language, the payload (aka the `param` key) is decoded as a raw string. This means that the parsing of data into its appropriate type must be done inside the procedure handler. For strings and primitive arrays (like `[]string`), V-JSONRPC provides functions for it (`as_array` for array and `as_string` for string).

```v
fn get_person(ctx mut Context) string {
    // The params is manually decoded into the Person struct
    person := json.decode(Person, ctx.req.params) or {}
    return person.str()
}
```

## Migration from `0.1`
V-JSONRPC 0.2 is different from the previous version when it comes to the function names and the way it is used. If you are using the previous version of V-JSONRPC and want to migrate to the new version, you should do the following:

- The built-in TCP server has been removed. Use the code from the [`tcp_example.v`](examples/tcp_example.v) to use V-JSONRPC via TCP.
- `register_procedure` is now `register`.

## Special thanks
Special huge thanks to [spytheman](https://github.com/spytheman/) for reviewing and fixing the code!

## Contributing
1. Fork it (<https://github.com/nedpals/v-jsonrpc/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## License
[MIT](LICENSE)

## Contributors

- [Ned Palacios](https://github.com/nedpals) - creator and maintainer
