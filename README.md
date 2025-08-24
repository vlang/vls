## VLS - V Language Server

Early alpha.

Build with: `v .`

Copy the binary to `/tmp/vls2`. Later it will be configurable via the extension settings.

Doesn't work on Windows yet, but it's easy to make it work.

#### Building the vscode vls extension

```
cd vscode-extension
npm install
npm run build
```

You should get a `vls-{version}.vsix` file.

Or download the `vsix` file from here:

https://github.com/vlang/vls/releases/download/0.1/vls-0.0.1.vsix

In VS Code run `Extensions: Install from VSIX...`


### Features

#### Instant errors

<img width="966" height="216" alt="image" src="https://github.com/user-attachments/assets/9db4b884-befe-4578-b844-9bcca537d9e5" />

#### Go to definition

https://github.com/user-attachments/assets/8a0f12cd-bbc2-472c-a3dc-d4b0b3745295


#### Autocomplete for module functions

<img width="623" height="296" alt="image" src="https://github.com/user-attachments/assets/31174738-705e-4579-bbf6-45e6e8c45d29" />

#### Information about function parameters

<img width="747" height="225" alt="image" src="https://github.com/user-attachments/assets/4cb16c6a-0784-4938-809d-f7b4770930a9" />

#### Autocomplete for struct fields and methods

<img width="902" height="196" alt="image" src="https://github.com/user-attachments/assets/c7ffb3e7-e92c-44be-bf6d-dc4c9e52eaaf" />



