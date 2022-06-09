module analyzer

pub interface ReportData{}

pub enum ReportKind {
	error
	warning
	notice
}

pub struct Report {
pub:
	kind      ReportKind
	code      string
	message   string
	file_path string
	source    string
	range     C.TSRange
	data      ReportData = 1
}

pub struct ReporterPreferences {
mut:
	limit              int = 100
	warns_are_errors   bool
}

pub interface Reporter {
	count() int
mut:
	prefs   ReporterPreferences
	report(r Report)
}

pub fn (r Reporter) reached_limit() bool {
	return r.count() >= r.prefs.limit
}

pub struct Collector {
pub mut:
	prefs    ReporterPreferences
	errors   []Report
	warnings []Report
	notices  []Report
}

pub fn (mut c Collector) clear() {
	c.errors.clear()
	c.warnings.clear()
	c.notices.clear()
}

pub fn (mut c Collector) report(r Report) {
	match r.kind {
		.error {
			c.errors << r
		}
		.warning {
			if c.prefs.warns_are_errors {
				c.report(Report{
					...r
					kind: .error
				})
				return
			}
			c.warnings << r
		}
		.notice {
			c.notices << r
		}
	}
}

pub fn (c &Collector) count() int {
	return c.errors.len + c.warnings.len + c.notices.len
}