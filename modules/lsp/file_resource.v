module lsp

pub struct CreateFileOptions {
	overwrite bool
	ignore_if_exists bool [json:ignoreIfExists]
}

pub struct CreateFile {
	kind string // 'create'
	uri string
	options CreateFileOptions
}

pub struct RenameFileOptions {
	overwrite bool
	ignore_if_exists bool [json:ignoreIfExists]
}

pub struct RenameFile {
	kind string // 'rename'
	old_uri string [json:oldUri]
	new_uri string [json:newUri]
	options RenameFileOptions
}

pub struct DeleteFileOptions {
	recursive bool
	ignore_if_exists bool [json:ignoreIfExists]
}

pub struct DeleteFile {
	kind string // 'delete'
	uri string
	options DeleteFileOptions
}

