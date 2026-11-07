from pathlib import Path
import base64, concurrent.futures, hashlib, re, subprocess, tempfile, urllib.request

repo = Path(__file__).resolve().parents[2]
commit = '745ee92b87ed62b5a8a1bac47d5df8cad623bf59'
files = {
    'system/stack/avdt/avdt_msg.cc': '87cfe2a2a7c5031316ad72e03fc665298c1cc47def26c59b794710856946fbab',
    'system/stack/avdt/avdt_defs.h': '35c80621cb4c1ffbecb665ea67cddad5cf47853bcfdc2db51363757956d3b455',
    'system/stack/a2dp/a2dp_vendor_ldac.cc': 'bd66039ee67cb5ea1e1e875dcd3fea361c6643712af7d248f462cffbc3b5754f',
    'system/stack/include/avdt_api.h': 'b872465f67955b5e99a3961e021443c6b3110004cbfe348eb562dc52b8d90b0e',
    'system/stack/include/a2dp_vendor_ldac_constants.h': '17358ca2eb01403df0004b97cddb4535cecaa3f4c8c86576ea827dc52e57de35',
    'system/internal_include/bt_target.h': '7f70cade27db5535aa908b6d743d144dffd69fa93ac7883a07e717eeb6aefba7',
}
services = '0100070a00ff2d010000aa001001'
fixtures = {
    'basic': services,
    'reordered': services[4:] + services[:4],
    'protection_repeated': services + '0402020004020300',
    'protection_short': services + '040102',
    'header_compression': services + '050100',
    'header_compression_short': services + '0500',
    'header_compression_long': services + '05020000',
    'multiplexing': services + '0603000000',
    'multiplexing_short': services + '06020000',
    'multiplexing_long': services + '06080000000000000000',
    'delay_reporting': services + '0800',
    'delay_reporting_long': services + '080100',
    'unknown_category': services + '0900',
}
discoveries = {
    'empty': '',
    'sinks': '040808080c08',
    'in_use': '0608',
    'source': '0400',
}


def fetch(path):
    url = 'https://android.googlesource.com/platform/packages/modules/Bluetooth/+/' + commit + '/' + path + '?format=TEXT'
    data = base64.b64decode(urllib.request.urlopen(url, timeout=30).read())
    if hashlib.sha256(data).hexdigest() != files[path]:
        raise ValueError('Pinned AOSP source hash mismatch: ' + path)
    return path, data


def bytes_literal(value):
    return ','.join('0x' + value[index:index + 2] for index in range(0, len(value), 2))


with tempfile.TemporaryDirectory(prefix='acouplet-aosp-protocol-') as directory:
    root = Path(directory)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(files)) as pool:
        for path, data in pool.map(fetch, files):
            destination = root / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    msg = (root / 'system/stack/avdt/avdt_msg.cc').read_text().splitlines(True)
    ldac = (root / 'system/stack/a2dp/a2dp_vendor_ldac.cc').read_text().splitlines(True)
    api = (root / 'system/stack/include/avdt_api.h').read_text().splitlines()
    target = (root / 'system/internal_include/bt_target.h').read_text().splitlines()
    macros = '\n'.join(line for line in api + target if re.match(
        r'#define AVDT_(ERR_\w+|PSC_\w+|RECOV_RFC2733|CODEC_SIZE|PROTECT_SIZE|MEDIA_TYPE_AUDIO)\b', line))
    reference = ''.join(msg[:27]) + ''.join(ldac[:16]) + r'''
#include <cstdint>
#include <cstring>
#include <cstdio>
#include <cstdlib>
#include "system/stack/avdt/avdt_defs.h"
#include "system/stack/include/a2dp_vendor_ldac_constants.h"
namespace bluetooth { namespace log {
template <typename... A> void error(const char*, A...) {}
template <typename... A> void verbose(const char*, A...) {}
} }
using namespace bluetooth;
'''
    reference += macros + r'''
#define AVDT_PSC_PROTECT (1 << 4)
#define AVDT_PSC_CODEC (1 << 7)
struct AvdtpSepConfig {
    uint16_t psc_mask;
    uint8_t num_codec, num_protect, recov_type, recov_mrws, recov_mnmp, hdrcmp_mask;
    uint8_t codec_info[AVDT_CODEC_SIZE], protect_info[AVDT_PROTECT_SIZE];
};
struct tA2DP_LDAC_CIE { uint32_t vendorId; uint16_t codecId; uint8_t sampleRate, channelMode; };
constexpr uint8_t A2DP_MEDIA_CT_NON_A2DP = 0xff;
struct tAVDT_SEP_INFO { bool in_use; uint8_t seid, media_type, tsep; };
struct tAVDT_MSG { struct { tAVDT_SEP_INFO* p_sep_info; uint8_t num_seps; } discover_rsp; };
'''
    reference += ''.join(msg[104:141]) + ''.join(msg[276:324]) + ''.join(msg[523:658])
    reference += ''.join(msg[874:903])
    reference += ''.join(ldac[108:140])
    reference += r'''
int main() {
    AvdtpSepConfig cfg{};
    uint8_t element;
'''
    native = r'''
#define main ProbeMain
#include "DirectAVDTPSustainedPlaybackProbe.m"
#undef main
int main(void) {
    @autoreleasepool {
'''
    for name, value in discoveries.items():
        reference += '{ uint8_t bytes[] = {' + (bytes_literal(value) or '0') + '};\n'
        reference += r'''
tAVDT_SEP_INFO endpoints[62]{};
tAVDT_MSG discovery{{endpoints, 62}};
'''
        reference += 'uint8_t error = avdt_msg_prs_discover_rsp(&discovery, bytes, ' + str(len(value) // 2) + ');\n'
        reference += r'''
unsigned sinks = 0;
for (unsigned index = 0; index < discovery.discover_rsp.num_seps; index++)
    if (!endpoints[index].in_use && endpoints[index].media_type == 0 && endpoints[index].tsep == 1) sinks++;
'''
        reference += 'printf("discovery_' + name + '=%d:%u\\n", !error, sinks); }\n'
        native += '{ const uint8_t bytes[] = {0x12, 0x01' + (',' + bytes_literal(value) if value else '') + '};\n'
        native += 'NSArray *sinks = DecodeReply([NSData dataWithBytes:bytes length:sizeof(bytes)], 1, 1, 0, NO);\n'
        native += 'printf("discovery_' + name + '=%d:%u\\n", sinks != nil, (unsigned)sinks.count); }\n'
    for name, value in fixtures.items():
        reference += '{ uint8_t bytes[] = {' + bytes_literal(value) + '};\n'
        reference += 'printf("semantic_' + name + '=%d\\n", !avdt_msg_prs_cfg(&cfg, bytes, sizeof(bytes), &element, AVDT_SIG_GET_ALLCAP)); }\n'
        native += '{ const uint8_t bytes[] = {0x12, 0x02,' + bytes_literal(value) + '};\n'
        native += 'NSData *reply = [NSData dataWithBytes:bytes length:sizeof(bytes)];\n'
        native += 'printf("semantic_' + name + '=%d\\n", DecodeReply(reply, 1, 2, 3, NO) != nil);\n'
        native += r'''
NSMutableData *incoming = [reply mutableCopy];
const uint8_t marker[] = {0xf1, 0x3f};
[incoming appendBytes:marker length:sizeof(marker)];
Parsed parsed;
BOOL framed = Parse(incoming.bytes, incoming.length, 1, 2, &parsed) == 1 &&
    parsed.responseLength == reply.length && parsed.consumed == incoming.length;
'''
        native += 'printf("framing_' + name + '=%d\\n", framed); }\n'
    for rate, rate_bit in ((44100, 0x20), (48000, 0x10), (88200, 0x08), (96000, 0x04)):
        reference += '{ tA2DP_LDAC_CIE codec{A2DP_LDAC_VENDOR_ID, A2DP_LDAC_CODEC_ID, ' + str(rate_bit) + ', 1};\n'
        reference += r'''
cfg = {};
cfg.psc_mask = AVDT_PSC_TRANS;
cfg.num_codec = 1;
if (!A2DP_BuildInfoLdac(0, &codec, cfg.codec_info)) return 1;
uint8_t bytes[128]{}, *out = bytes;
avdt_msg_bld_cfg(&out, &cfg);
'''
        reference += 'printf("build_' + str(rate) + '="); for (uint8_t* p = bytes; p < out; p++) printf("%02x", *p); puts(""); }\n'
        native += '{ NSData *data = ServiceBytes(' + str(rate) + ', NO); const uint8_t *bytes = data.bytes;\n'
        native += 'printf("build_' + str(rate) + '="); for (NSUInteger i = 0; i < data.length; i++) printf("%02x", bytes[i]); puts(""); }\n'
    reference += r'''
uint8_t header[2], *out = header;
AVDT_MSG_BLD_HDR(out, 1, AVDT_PKT_TYPE_SINGLE, AVDT_MSG_TYPE_GRJ);
AVDT_MSG_BLD_SIG(out, AVDT_SIG_GET_ALLCAP);
printf("general_reject=%ld\n", out - header);
return 0;
}
'''
    native += r'''
const uint8_t reject[] = {0x11, 0x0c};
printf("general_reject=%lu\n", FixedResponseLength(reject, sizeof(reject), 1, 12));
return 0;
    }
}
'''
    cpp = root / 'reference.cc'
    objc = root / 'native.m'
    cpp.write_text(reference)
    objc.write_text(native)
    reference_binary = root / 'reference'
    native_binary = root / 'native'
    subprocess.run(['/usr/bin/xcrun', 'clang++', '-std=c++17', '-Wall', '-Wextra', '-Werror', '-I', str(root),
                    str(cpp), '-o', str(reference_binary)], check=True)
    subprocess.run(['/usr/bin/xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror', '-D_DARWIN_C_SOURCE',
                    '-DACOUPLET_LDAC_PROBE_ONLY=0', '-mmacosx-version-min=15.4', '-framework', 'Foundation',
                    '-framework', 'CoreFoundation', '-framework', 'CoreBluetooth', '-framework', 'IOBluetooth',
                    '-I', str(repo / 'Helpers/LDAC'), str(objc), '-o', str(native_binary)], check=True)
    expected = dict(line.split('=', 1) for line in subprocess.check_output([str(reference_binary)], text=True).splitlines())
    actual = dict(line.split('=', 1) for line in subprocess.check_output([str(native_binary)], text=True).splitlines())
    capabilities = {name: expected['semantic_' + name] for name in fixtures}
    assert expected.pop('semantic_unknown_category') == '1'
    for name, value in expected.items():
        assert actual.get(name) == value, f'{name}: AOSP={value}, Acouplet={actual.get(name)}'
    print(f'AOSP_PROTOCOL_PASS commit={commit} comparisons={len(expected)} hardware_access=0')
    print('Scope: extracted AOSP discovery/capability parsers and LDAC/configuration builders versus production semantic decoding and generated bytes.')
    for name, valid in capabilities.items():
        if valid == '1':
            semantic = actual['semantic_' + name] == '1'
            framing = actual['framing_' + name] == '1'
            print(f'CAPABILITY_RECEIVE name={name} semantic={int(semantic)} framing={int(framing)} supported={int(semantic and framing)}')
    print('Receive support above is measured from the current decoder and stream parser; semantic comparisons alone do not establish reception.')
    print('Not covered: fragmented signaling reassembly or variable-length peer command handling.')
