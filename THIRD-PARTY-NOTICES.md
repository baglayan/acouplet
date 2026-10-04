# Third-party notices

## Upstream application

Acouplet is built upon [Maadlou/xm5-control-macos](https://github.com/Maadlou/xm5-control-macos),
Copyright (c) 2026 Mohamed Emad. The MIT license is included in `LICENSE`.

## Sony artwork and trademarks

Sony product photographs, where included, are © Sony Corporation and are not
covered by the application's MIT license.

Sony and its product names are trademarks of Sony Corporation. Acouplet is
an independent project and is not endorsed by Sony or Apple.

## SonyBridge

SonyBridge (commit `8c81a27`)
provided the battery protocol reference in `Client/Headphones.cpp`.

MIT License

Copyright (c) 2020 Nir Harel, Mor Gal, Sem Visscher, jimzrt, guilhermealbm, and other contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## Sparkle

Acouplet uses [Sparkle 2.10.0](https://sparkle-project.org),
licensed under the MIT license. Its copyright notices, license and bundled
component notices are included in `Sparkle-LICENSE.txt`.

## LDAC encoder

Acouplet uses Sony Corporation's LDAC encoder from
[AOSP platform/external/libldac](https://android.googlesource.com/platform/external/libldac/+/eeee1a3f5f8df1282e3a6d297085885fd886737b/),
revision `eeee1a3f5f8df1282e3a6d297085885fd886737b`,
Copyright (C) 2003–2017 Sony Corporation, under the Apache License 2.0.
The license and upstream notice are included in `LDAC-LICENSE.txt` and
`LDAC-NOTICE.txt`.

The upstream notice requires LDAC product certification and links to
[Sony's LDAC AOSP information](https://www.sony.net/Products/LDAC/aosp/).
This app is not Sony-certified. LDAC is a trademark of Sony Corporation.

## Apple audio driver sample

The LDAC output driver is based on Apple's `NullAudio.c` sample,
Copyright © 2024 Apple Inc. Apple's permission and warranty
notice is included in the driver's `Contents/Resources/LICENSE.txt` and in
`Helpers/LDAC/VirtualOutput/LICENSE.txt` in the source repository.

## Protocol references

[SonyHeadphonesClient](https://github.com/mos9527/SonyHeadphonesClient) protocol
schemas and device captures were consulted at revisions
`965c458116d40827494726447de5f07eb50efcb8` and
`36712f3cfc341612993ba991a517380354c9a767`.

MIT License

Copyright (c) 2026 mos9527, Amr Satrio and other contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

[Gadgetbridge](https://github.com/Freeyourgadget/Gadgetbridge) was consulted for
battery and firmware response formats. No Gadgetbridge source code is included.
