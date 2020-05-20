/**
 * vargs 0.4.2
 * https://github.com/nedpals/vargs
 * 
 * (c) 2019 Ned Palacios and its contributors.
 */

module vargs

pub struct Args {
pub mut:
    command string
    options map[string]string
    unknown []string
}

fn parse_option(v string) []string {
    delimitter := if v.starts_with('--') { '--' } else { '-' } 
    val := v.replace(delimitter, '')

    return val.split('=')
}

fn starts_with_hypen(v string) bool {
    return v.starts_with('-') || v.starts_with('--')
}

fn (v mut Args) insert_option(name string, val string) {
    v.options[name] = if name in v.options {
        '${v.options[name]},${val}'
    } else {
        val
    }
}

pub fn parse(a []string, start int) Args {
    args := a[start..a.len]
    mut parsed := Args{'', map[string]string, []string}

    for i, curr in args {
        next := if i+1 > args.len-1 { '' } else { args[i+1] }
        prev := if i-1 <= 0 { '' } else { args[i-1] }
        
        if i == 0 && !starts_with_hypen(curr) {
            parsed.command = curr
        }

        if (starts_with_hypen(prev) && parse_option(prev).len == 1) && !starts_with_hypen(curr) {
            prev_opt := parse_option(prev)
            parsed.insert_option(prev_opt[0], curr)
        }

        if starts_with_hypen(curr) {
            opt := parse_option(curr)
            match opt.len {
                1 { if next.len == 0 { parsed.options[opt[0]] = '' } }
                2 { parsed.insert_option(opt[0], opt[1]) }
                else {}
            }
        }

        if i != 0 && (!starts_with_hypen(prev) || parse_option(prev).len == 2) && !starts_with_hypen(curr) {
            parsed.unknown << curr
        }
    }

    return parsed
}

pub fn (v Args) array_option(name string) []string {
    opt_values := v.options[name].split(',')

    return opt_values
}

pub fn (v Args) str() string {
    mut opts := v.options.str().split_into_lines()
    for i, el in opts { opts[i] = el.trim_space() }
    opts_str := opts.join(' ')

    return '\{ command: "${v.command}", options: ${opts_str}, unknown: ${v.unknown.str()} \}'
}
