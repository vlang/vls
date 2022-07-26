module analyzer

import datatypes { Stack }

fn within_range(node_range C.TSRange, start_line u32, end_line u32) bool {
	return (node_range.start_point.row >= start_line && node_range.start_point.row <= end_line)
		|| (node_range.end_point.row >= start_line && node_range.end_point.row <= end_line)
}

