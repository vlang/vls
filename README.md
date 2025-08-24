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

<img width="1932" height="432" alt="image" src="https://github.com/user-attachments/assets/a842e103-b3c2-427f-956f-fffff07970dc" />

#### Go to definition

https://github.com/user-attachments/assets/fb4ee6ff-4765-46b7-a21e-267691253d8e


#### Autocomplete for module functions

<img width="1246" height="592" alt="image" src="https://github.com/user-attachments/assets/0d4e1849-2e6c-47f8-9a45-322fe25d9bef" />

#### Information about function parameters

<img width="1494" height="450" alt="image" src="https://github.com/user-attachments/assets/46cc391b-fcdc-4083-ab62-97edd815ddd9" />

#### Autocomplete for struct fields and methods

<img width="1804" height="392" alt="image" src="https://github.com/user-attachments/assets/478bfd20-201a-476f-88cd-583fad52d6cc" />



