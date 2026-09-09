## VLS - V Language Server

Build with: `v .`

Place the vls binary in your `PATH`. For example, on Linux you can place it in `/usr/local/bin`. On
Windows, you can place it in a directory that is included in your `PATH`
environment variable.

Otherwise, you can set the path to the vls binary in your editor's settings.

#### Building the vscode vls extension

```
cd vscode-extension
npm install
npm run build
```

You should get a `vls-{version}.vsix` file.

Or download the `vsix` file from here:

https://github.com/vlang/vls/releases/

In VS Code run `Extensions: Install from VSIX...`

The extension includes `V: Build`, `V: Run`, and `V: Test` in the Command Palette and in
`Tasks: Run Task`. Runnable CodeLens actions open a task terminal so program and compiler output is
always visible. Set `vls.vCommand` when the V compiler is not available through VS Code's `PATH`.

### Features

#### Instant errors

<img width="1932" height="432" alt="image" src="https://github.com/user-attachments/assets/a842e103-b3c2-427f-956f-fffff07970dc" />

#### Go to definition

https://github.com/user-attachments/assets/fb4ee6ff-4765-46b7-a21e-267691253d8e

#### Autocomplete for module functions

<img width="1246" height="592" alt="image" src="https://github.com/user-attachments/assets/0d4e1849-2e6c-47f8-9a45-322fe25d9bef" />

#### Information about function parameters

<img width="1494" height="450" alt="image" src="https://github.com/user-attachments/assets/46cc391b-fcdc-4083-ab62-97edd815ddd9" />

#### Autocomplete for struct fields and methods

<img width="1804" height="392" alt="image" src="https://github.com/user-attachments/assets/478bfd20-201a-476f-88cd-583fad52d6cc" />
