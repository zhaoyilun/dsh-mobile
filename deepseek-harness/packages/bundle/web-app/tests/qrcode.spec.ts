/**
 * Vendored QR encoder verification: a known-answer matrix assertion for
 * "HELLO WORLD" (the canonical QR example), structural checks of the function
 * patterns, determinism and version growth, and the terminal renderer's
 * consistency with the encoder matrix plus its required quiet zone.
 */

import { describe, expect, it } from 'vitest'
import qrcodegen from '../src/qrcode.ts'
import { renderQrTerminal } from '../src/pairing.ts'

/** Expected 21×21 matrix for `QrCode.encodeText('HELLO WORLD', Ecc.MEDIUM)`, row-major, 1 = dark. */
const HELLO_WORLD_V1_M: readonly string[] = [
  '111111101100001111111',
  '100000101001001000001',
  '101110101001101011101',
  '101110101000001011101',
  '101110101010001011101',
  '100000100010001000001',
  '111111101010101111111',
  '000000001000000000000',
  '011010110000101011111',
  '010000001111000010001',
  '001101110110001011000',
  '011011010011010101110',
  '100010101011101110101',
  '000000001101001000101',
  '111111101010000101100',
  '100000100101101101000',
  '101110101010001111111',
  '101110100101010100010',
  '101110101001011101001',
  '100000101011110001011',
  '111111100001011100001',
]

/** The 7×7 finder pattern (dark ring with a light separator), 1 = dark. */
const FINDER: readonly string[] = [
  '1111111',
  '1000001',
  '1011101',
  '1011101',
  '1011101',
  '1000001',
  '1111111',
]

function expectModule(qr: qrcodegen.QrCode, x: number, y: number, dark: boolean): void {
  expect(qr.getModule(x, y)).toBe(dark)
}

function expectFinder(qr: qrcodegen.QrCode, x: number, y: number): void {
  for (let dy = 0; dy < 7; dy++) {
    const row = FINDER[dy]!
    for (let dx = 0; dx < 7; dx++) expectModule(qr, x + dx, y + dy, row[dx]! === '1')
  }
}

describe('vendored QR encoder', () => {
  it('encodes "HELLO WORLD" to the pinned version-1 matrix', () => {
    const qr = qrcodegen.QrCode.encodeText('HELLO WORLD', qrcodegen.QrCode.Ecc.MEDIUM)
    expect(qr.version).toBe(1)
    expect(qr.size).toBe(21)
    for (let y = 0; y < qr.size; y++) {
      for (let x = 0; x < qr.size; x++) {
        expectModule(qr, x, y, HELLO_WORLD_V1_M[y]![x]! === '1')
      }
    }
  })

  it('draws the finder, timing, and dark-module function patterns', () => {
    const qr = qrcodegen.QrCode.encodeText('HELLO WORLD', qrcodegen.QrCode.Ecc.MEDIUM)
    expectFinder(qr, 0, 0)
    expectFinder(qr, 14, 0)
    expectFinder(qr, 0, 14)
    // Horizontal timing pattern on row 6, alternating from dark at column 8.
    for (let i = 0; i < 5; i++) expectModule(qr, 8 + i, 6, i % 2 === 0)
    // Vertical timing pattern on column 6, alternating from dark at row 8.
    for (let i = 0; i < 5; i++) expectModule(qr, 6, 8 + i, i % 2 === 0)
    // The dark module is always dark (row 13, column 8 for version 1).
    expectModule(qr, 8, 13, true)
  })

  it('is deterministic and grows the version with longer payloads', () => {
    const payload = 'http://192.168.1.5:3080/pair?token=secret-token-9f2c'
    const first = qrcodegen.QrCode.encodeText(payload, qrcodegen.QrCode.Ecc.LOW)
    const second = qrcodegen.QrCode.encodeText(payload, qrcodegen.QrCode.Ecc.LOW)
    expect(first.size).toBe(second.size)
    for (let y = 0; y < first.size; y++) {
      for (let x = 0; x < first.size; x++) expect(first.getModule(x, y)).toBe(second.getModule(x, y))
    }
    expect(qrcodegen.QrCode.encodeText('x'.repeat(300), qrcodegen.QrCode.Ecc.LOW).version).toBeGreaterThan(1)
  })

  it('renders the terminal half-block art from the encoder matrix plus a quiet zone', () => {
    const qr = qrcodegen.QrCode.encodeText('HELLO WORLD', qrcodegen.QrCode.Ecc.LOW)
    const rendered = renderQrTerminal('HELLO WORLD')
    const lines = rendered.split('\n')
    const width = qr.size + 8
    expect(lines).toHaveLength(Math.ceil(width / 2))
    for (const line of lines) {
      expect(line).toHaveLength(width)
      for (const char of line) expect(' ▀▄█').toContain(char)
    }
    // Every rendered cell matches the encoder matrix shifted by the quiet zone.
    for (let y = 0; y < width; y += 2) {
      for (let x = 0; x < width; x++) {
        const moduleX = x - 4
        const topRow = y - 4
        const top = topRow >= 0 && topRow < qr.size && moduleX >= 0 && moduleX < qr.size && qr.getModule(moduleX, topRow)
        const bottomRow = topRow + 1
        const bottom = bottomRow >= 0 && bottomRow < qr.size && moduleX >= 0 && moduleX < qr.size && qr.getModule(moduleX, bottomRow)
        const expected = top ? (bottom ? '█' : '▀') : (bottom ? '▄' : ' ')
        expect(lines[y / 2]![x]).toBe(expected)
      }
    }
  })
})
