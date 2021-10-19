module lsp

import os

type DocumentUri = string

pub fn (du DocumentUri) dir() string {
	return os.dir(du)
}

pub fn (du DocumentUri) path() string {
	$if windows {
		return du.all_after('file:///').replace_each(['/', '\\', '%3A', ':'])
	}
	return if du.starts_with('file://') { du.all_after('file://') } else { '' }
}

pub fn (du DocumentUri) dir_path() string {
	return os.dir(du.path())
}

pub fn document_uri_from_path(path string) DocumentUri {
	$if windows {
		uri_path := path.replace_each(['\\', '/', ':', '%3A'])
		return if !path.starts_with('file:///') { 'file:///' + uri_path } else { uri_path }
	}
	return if !path.starts_with('file://') { 'file://' + path } else { path }
}

pub struct NotificationMessage {
	method string
	params string [raw]
}

// // method: $/cancelRequest
pub struct CancelParams {
	id int
}

pub struct Command {
	title     string
	command   string
	arguments []string
}

pub struct DocumentFilter {
	language string
	scheme   string
	pattern  string
}

pub struct TextDocumentRegistrationOptions {
	document_selector []DocumentFilter [json: documentSelector]
}
