#!/usr/bin/env python3
"""Offline manifest/ABI/size consistency check; run after forge build.

Field shape follows Identity-md/worker's UniV4HookManifest (public main branch,
2026-10-08). This is a local cross-check, not network attestation.
"""
import json
from pathlib import Path

manifest = json.loads(Path('launch.json').read_text())
assert manifest['kind'] == 'univ4_hook'
assert set(manifest) == {'kind', 'hook', 'token', 'pool', 'notes'}
assert manifest['hook']['contract'] == 'SIMDTESTHook'
assert manifest['hook']['constructorArgs'] == ['$poolManager', '$token']
permissions = ['beforeInitialize', 'beforeSwap', 'afterSwap', 'beforeSwapReturnDelta', 'afterSwapReturnDelta']
assert manifest['hook']['permissions'] == permissions
assert manifest['token'] == {'contract': 'SIMDTEST', 'name': 'SIMDTEST', 'symbol': 'SIMDTEST', 'decimals': 18}
assert manifest['pool'] == {'pairedCurrency': '0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7', 'fee': 12500, 'tickSpacing': 60, 'initialPrice': '79228162514264337593543950336'}
assert isinstance(manifest['notes'], str) and len(manifest['notes']) <= 4000
for contract in ['SIMDTEST', 'SIMDTESTHook', 'SIMDTESTRouter']:
    artifact = json.loads(Path(f'out/{contract}.sol/{contract}.json').read_text())
    constructor = next(row for row in artifact['abi'] if row['type'] == 'constructor')
    expected = {'SIMDTEST': [], 'SIMDTESTHook': ['address', 'address'], 'SIMDTESTRouter': ['address'] * 3}[contract]
    assert [arg['type'] for arg in constructor['inputs']] == expected
    creation = bytes.fromhex(artifact['bytecode']['object'].removeprefix('0x'))
    runtime = bytes.fromhex(artifact['deployedBytecode']['object'].removeprefix('0x'))
    assert len(creation) + 32 * len(expected) <= 49152
    assert 0 < len(runtime) <= 24576
    i = 0
    while i < len(runtime):
        op = runtime[i]
        assert op not in (0xff, 0xf4, 0xf2), (contract, i, hex(op))
        i += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
    exported = Path(f'docs/abi/{contract}.json')
    exported.write_text(json.dumps(artifact['abi'], indent=2) + '\n')
    print(f'{contract}: creation + constructor {len(creation) + 32 * len(expected)} bytes; runtime {len(runtime)} bytes; ABI exported')
print('Manifest shape, constructor arguments, flags, bytecode limits, and forbidden opcodes: OK')
