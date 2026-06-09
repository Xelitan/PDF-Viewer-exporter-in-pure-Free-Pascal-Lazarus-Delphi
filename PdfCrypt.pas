unit PdfCrypt;
{$mode delphi}{$H+}{$R-}{$Q-}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

//PDF standard security handler: decrypts encrypted PDFs.
//Supports every standard scheme:
//   V1/V2 (R2/R3)  -> RC4 (40..128-bit)
//   V4   (R4)      -> RC4 or AESV2 (AES-128) via crypt filters
//   V5   (R5/R6)   -> AESV3 (AES-256)
//Primitives (RC4, AES, MD5, SHA-2) are self-contained; only md5 + the SHAxxx
//units are used. Authenticates the user OR owner password (empty by default).


interface

uses SysUtils, md5, SHA256, SHA384, SHA512;

type
  TPdfBytes = TBytes;  // same as PdfTypes.TPdfBytes -> seamless interop with the parser

  // How a stream/string is encrypted (resolved from /V and the crypt filters).
  TPdfCryptMethod = (cmIdentity, cmRC4, cmAESV2, cmAESV3);

  TPdfSecurityHandler = class
  private
    FO, FU, FOE, FUE, FID: TPdfBytes;
    FP: LongInt;
    FEncMeta: Boolean;
    FKeyLen: Integer;  // file key length in bytes
    FFileKey: TPdfBytes;
    function ComputeKeyRC4(const Pwd: TPdfBytes): TPdfBytes;
    function AuthUserRC4(const Pwd: TPdfBytes): Boolean;
    function AuthOwnerRC4(const Pwd: TPdfBytes): Boolean;
    function AuthUserV5(const Pwd: TPdfBytes): Boolean;
    function AuthOwnerV5(const Pwd: TPdfBytes): Boolean;
    function ObjKey(ObjNum, Gen: Integer; AES: Boolean): TPdfBytes;
  public
    R, V: Integer;
    StmMethod, StrMethod: TPdfCryptMethod;
    Authenticated: Boolean;
    // Initialise from the /Encrypt dictionary fields (all already extracted by the
    // caller) plus the first /ID string and a candidate password. Returns True if
    // the password (as user OR owner) unlocks the document.
    function Setup(AR, AV, ALengthBits: Integer;
                   const AO, AU, AOE, AUE, AID: TPdfBytes;
                   AP: LongInt; AEncMeta: Boolean;
                   AStm, AStr: TPdfCryptMethod;
                   const Password: AnsiString): Boolean;
    // Decrypt one object's string/stream bytes.
    function Decrypt(const Data: TPdfBytes; ObjNum, Gen: Integer; IsString: Boolean): TPdfBytes;
  end;

// Stand-alone primitives (exposed for testing).
function RC4Crypt(const Key, Data: TPdfBytes): TPdfBytes;
function AESBlockEncrypt(const Key, Block: TPdfBytes): TPdfBytes;  // single 16-byte block
function AESBlockDecrypt(const Key, Block: TPdfBytes): TPdfBytes;

implementation

const
  // 32-byte standard password padding (PDF 1.7, 7.6.3.3).
  PAD: array[0..31] of Byte = (
    $28,$BF,$4E,$5E,$4E,$75,$8A,$41,$64,$00,$4E,$56,$FF,$FA,$01,$08,
    $2E,$2E,$00,$B6,$D0,$68,$3E,$80,$2F,$0C,$A9,$FE,$64,$53,$69,$7A);

  // AES S-box and inverse S-box.
  SBOX: array[0..255] of Byte = (
    $63,$7c,$77,$7b,$f2,$6b,$6f,$c5,$30,$01,$67,$2b,$fe,$d7,$ab,$76,
    $ca,$82,$c9,$7d,$fa,$59,$47,$f0,$ad,$d4,$a2,$af,$9c,$a4,$72,$c0,
    $b7,$fd,$93,$26,$36,$3f,$f7,$cc,$34,$a5,$e5,$f1,$71,$d8,$31,$15,
    $04,$c7,$23,$c3,$18,$96,$05,$9a,$07,$12,$80,$e2,$eb,$27,$b2,$75,
    $09,$83,$2c,$1a,$1b,$6e,$5a,$a0,$52,$3b,$d6,$b3,$29,$e3,$2f,$84,
    $53,$d1,$00,$ed,$20,$fc,$b1,$5b,$6a,$cb,$be,$39,$4a,$4c,$58,$cf,
    $d0,$ef,$aa,$fb,$43,$4d,$33,$85,$45,$f9,$02,$7f,$50,$3c,$9f,$a8,
    $51,$a3,$40,$8f,$92,$9d,$38,$f5,$bc,$b6,$da,$21,$10,$ff,$f3,$d2,
    $cd,$0c,$13,$ec,$5f,$97,$44,$17,$c4,$a7,$7e,$3d,$64,$5d,$19,$73,
    $60,$81,$4f,$dc,$22,$2a,$90,$88,$46,$ee,$b8,$14,$de,$5e,$0b,$db,
    $e0,$32,$3a,$0a,$49,$06,$24,$5c,$c2,$d3,$ac,$62,$91,$95,$e4,$79,
    $e7,$c8,$37,$6d,$8d,$d5,$4e,$a9,$6c,$56,$f4,$ea,$65,$7a,$ae,$08,
    $ba,$78,$25,$2e,$1c,$a6,$b4,$c6,$e8,$dd,$74,$1f,$4b,$bd,$8b,$8a,
    $70,$3e,$b5,$66,$48,$03,$f6,$0e,$61,$35,$57,$b9,$86,$c1,$1d,$9e,
    $e1,$f8,$98,$11,$69,$d9,$8e,$94,$9b,$1e,$87,$e9,$ce,$55,$28,$df,
    $8c,$a1,$89,$0d,$bf,$e6,$42,$68,$41,$99,$2d,$0f,$b0,$54,$bb,$16);

  INVSBOX: array[0..255] of Byte = (
    $52,$09,$6a,$d5,$30,$36,$a5,$38,$bf,$40,$a3,$9e,$81,$f3,$d7,$fb,
    $7c,$e3,$39,$82,$9b,$2f,$ff,$87,$34,$8e,$43,$44,$c4,$de,$e9,$cb,
    $54,$7b,$94,$32,$a6,$c2,$23,$3d,$ee,$4c,$95,$0b,$42,$fa,$c3,$4e,
    $08,$2e,$a1,$66,$28,$d9,$24,$b2,$76,$5b,$a2,$49,$6d,$8b,$d1,$25,
    $72,$f8,$f6,$64,$86,$68,$98,$16,$d4,$a4,$5c,$cc,$5d,$65,$b6,$92,
    $6c,$70,$48,$50,$fd,$ed,$b9,$da,$5e,$15,$46,$57,$a7,$8d,$9d,$84,
    $90,$d8,$ab,$00,$8c,$bc,$d3,$0a,$f7,$e4,$58,$05,$b8,$b3,$45,$06,
    $d0,$2c,$1e,$8f,$ca,$3f,$0f,$02,$c1,$af,$bd,$03,$01,$13,$8a,$6b,
    $3a,$91,$11,$41,$4f,$67,$dc,$ea,$97,$f2,$cf,$ce,$f0,$b4,$e6,$73,
    $96,$ac,$74,$22,$e7,$ad,$35,$85,$e2,$f9,$37,$e8,$1c,$75,$df,$6e,
    $47,$f1,$1a,$71,$1d,$29,$c5,$89,$6f,$b7,$62,$0e,$aa,$18,$be,$1b,
    $fc,$56,$3e,$4b,$c6,$d2,$79,$20,$9a,$db,$c0,$fe,$78,$cd,$5a,$f4,
    $1f,$dd,$a8,$33,$88,$07,$c7,$31,$b1,$12,$10,$59,$27,$80,$ec,$5f,
    $60,$51,$7f,$a9,$19,$b5,$4a,$0d,$2d,$e5,$7a,$9f,$93,$c9,$9c,$ef,
    $a0,$e0,$3b,$4d,$ae,$2a,$f5,$b0,$c8,$eb,$bb,$3c,$83,$53,$99,$61,
    $17,$2b,$04,$7e,$ba,$77,$d6,$26,$e1,$69,$14,$63,$55,$21,$0c,$7d);

// =-=-=-=-=-=-=-=-=-=-=-=-─ helpers =-=-=-=-=-=-=-=-=-=-=-=-─
function BCat(const A, B: TPdfBytes): TPdfBytes;
begin
  SetLength(Result, Length(A) + Length(B));
  if Length(A) > 0 then Move(A[0], Result[0], Length(A));
  if Length(B) > 0 then Move(B[0], Result[Length(A)], Length(B));
end;

function Slice(const A: TPdfBytes; Start, Count: Integer): TPdfBytes;
var i: Integer;
begin
  if Start < 0 then Start := 0;
  if Start + Count > Length(A) then Count := Length(A) - Start;
  if Count < 0 then Count := 0;
  SetLength(Result, Count);
  for i := 0 to Count-1 do Result[i] := A[Start+i];
end;

function SameBytes(const A, B: TPdfBytes; N: Integer): Boolean;
var i: Integer;
begin
  if (Length(A) < N) or (Length(B) < N) then Exit(False);
  for i := 0 to N-1 do if A[i] <> B[i] then Exit(False);
  Result := True;
end;

function MD5OfBytes(const Data: TPdfBytes; Len: Integer): TPdfBytes;
var dig: TMD5Digest;
begin
  if Len < 0 then Len := Length(Data);
  if Len = 0 then dig := MD5Buffer(PAD, 0)   // dummy ptr, 0 len
  else dig := MD5Buffer(Data[0], Len);
  SetLength(Result, 16);
  Move(dig[0], Result[0], 16);
end;

function StrToBytes(const S: AnsiString): TPdfBytes;
var i: Integer;
begin
  SetLength(Result, Length(S));
  for i := 1 to Length(S) do Result[i-1] := Byte(S[i]);
end;

// Pad/truncate a password to the 32-byte field (Algorithm 2 step a).
function PadPwd(const Pwd: TPdfBytes): TPdfBytes;
var n, i: Integer;
begin
  SetLength(Result, 32);
  n := Length(Pwd);
  if n > 32 then n := 32;
  for i := 0 to n-1 do Result[i] := Pwd[i];
  for i := n to 31 do Result[i] := PAD[i - n];
end;

// =-=-=-=-=-=-=-=-=-=-=-=-─ RC4 =-=-=-=-=-=-=-=-=-=-=-=-─
function RC4Crypt(const Key, Data: TPdfBytes): TPdfBytes;
var S: array[0..255] of Byte;
  i, j, k, t, kl: Integer;
begin
  kl := Length(Key);
  SetLength(Result, Length(Data));
  if kl = 0 then begin
    Result := Copy(Data);
    Exit;
  end;
  for i := 0 to 255 do S[i] := i;
  j := 0;
  for i := 0 to 255 do
  begin
    j := (j + S[i] + Key[i mod kl]) and 255;
    t := S[i];
    S[i] := S[j];
    S[j] := t;
  end;
  i := 0;
  j := 0;
  for k := 0 to High(Data) do
  begin
    i := (i + 1) and 255;
    j := (j + S[i]) and 255;
    t := S[i];
    S[i] := S[j];
    S[j] := t;
    Result[k] := Data[k] xor S[(S[i] + S[j]) and 255];
  end;
end;

// =-=-=-=-=-=-=-=-=-=-=-=-─ AES =-=-=-=-=-=-=-=-=-=-=-=-─
type
  TAES = object
    Nk, Nr: Integer;
    RK: array[0..239] of Byte;  // expanded key (max 15 round keys * 16)
    procedure Init(const Key: TPdfBytes);
    procedure EncryptBlock(var B: array of Byte);
    procedure DecryptBlock(var B: array of Byte);
  end;

function XTime(x: Byte): Byte;
inline;
begin
  if (x and $80) <> 0 then Result := Byte((x shl 1) xor $1B)
  else Result := Byte(x shl 1);
end;

function GMul(a, b: Byte): Byte;
var p, i: Byte;
begin
  p := 0;
  for i := 0 to 7 do
  begin
    if (b and 1) <> 0 then p := p xor a;
    b := b shr 1;
    a := XTime(a);
  end;
  Result := p;
end;

procedure TAES.Init(const Key: TPdfBytes);
var i, words, t0,t1,t2,t3, tmp: Integer;
  rcon: Byte;
begin
  Nk := Length(Key) div 4;  // 4 or 8
  Nr := Nk + 6;  // 10 or 14
  words := 4 * (Nr + 1);
  for i := 0 to Length(Key)-1 do RK[i] := Key[i];
  rcon := 1;
  i := Nk;
  while i < words do
  begin
    t0 := RK[(i-1)*4];
    t1 := RK[(i-1)*4+1];
    t2 := RK[(i-1)*4+2];
    t3 := RK[(i-1)*4+3];
    if (i mod Nk) = 0 then
    begin
      // RotWord + SubWord + Rcon
      tmp := t0;
      t0 := SBOX[t1];
      t1 := SBOX[t2];
      t2 := SBOX[t3];
      t3 := SBOX[tmp];
      t0 := t0 xor rcon;
      rcon := XTime(rcon);
    end
    else if (Nk > 6) and ((i mod Nk) = 4) then
    begin
      t0 := SBOX[t0];
      t1 := SBOX[t1];
      t2 := SBOX[t2];
      t3 := SBOX[t3];
    end;
    RK[i*4]   := RK[(i-Nk)*4]   xor t0;
    RK[i*4+1] := RK[(i-Nk)*4+1] xor t1;
    RK[i*4+2] := RK[(i-Nk)*4+2] xor t2;
    RK[i*4+3] := RK[(i-Nk)*4+3] xor t3;
    Inc(i);
  end;
end;

procedure TAES.EncryptBlock(var B: array of Byte);
var s: array[0..15] of Byte;
  r, c, k, i: Integer;
  t: array[0..3] of Byte;
  a0,a1,a2,a3: Byte;
begin
  for i := 0 to 15 do s[i] := B[i] xor RK[i];  // AddRoundKey 0
  for r := 1 to Nr do
  begin
    // SubBytes
    for i := 0 to 15 do s[i] := SBOX[s[i]];
    // ShiftRows: element (row,col) at index row+4*col; row r shifts left by r
    for k := 1 to 3 do
    begin
      t[0] := s[k];
      t[1] := s[k+4];
      t[2] := s[k+8];
      t[3] := s[k+12];
      s[k] := t[k];
      s[k+4] := t[(k+1) and 3];
      s[k+8] := t[(k+2) and 3];
      s[k+12] := t[(k+3) and 3];
    end;
    if r < Nr then
      for c := 0 to 3 do                                 // MixColumns
      begin
        a0 := s[c*4];
        a1 := s[c*4+1];
        a2 := s[c*4+2];
        a3 := s[c*4+3];
        s[c*4]   := GMul(a0,2) xor GMul(a1,3) xor a2 xor a3;
        s[c*4+1] := a0 xor GMul(a1,2) xor GMul(a2,3) xor a3;
        s[c*4+2] := a0 xor a1 xor GMul(a2,2) xor GMul(a3,3);
        s[c*4+3] := GMul(a0,3) xor a1 xor a2 xor GMul(a3,2);
      end;
    for i := 0 to 15 do s[i] := s[i] xor RK[r*16 + i];  // AddRoundKey r
  end;
  for i := 0 to 15 do B[i] := s[i];
end;

procedure TAES.DecryptBlock(var B: array of Byte);
var s: array[0..15] of Byte;
  r, c, k, i: Integer;
  t: array[0..3] of Byte;
  a0,a1,a2,a3: Byte;
begin
  for i := 0 to 15 do s[i] := B[i] xor RK[Nr*16 + i];  // AddRoundKey Nr
  for r := Nr-1 downto 0 do
  begin
    // InvShiftRows: row k shifts right by k
    for k := 1 to 3 do
    begin
      t[0] := s[k];
      t[1] := s[k+4];
      t[2] := s[k+8];
      t[3] := s[k+12];
      s[k] := t[(4-k) and 3];
      s[k+4] := t[(5-k) and 3];
      s[k+8] := t[(6-k) and 3];
      s[k+12] := t[(7-k) and 3];
    end;
    // InvSubBytes
    for i := 0 to 15 do s[i] := INVSBOX[s[i]];
    for i := 0 to 15 do s[i] := s[i] xor RK[r*16 + i];  // AddRoundKey r
    if r > 0 then
      for c := 0 to 3 do                                 // InvMixColumns
      begin
        a0 := s[c*4];
        a1 := s[c*4+1];
        a2 := s[c*4+2];
        a3 := s[c*4+3];
        s[c*4]   := GMul(a0,14) xor GMul(a1,11) xor GMul(a2,13) xor GMul(a3,9);
        s[c*4+1] := GMul(a0,9)  xor GMul(a1,14) xor GMul(a2,11) xor GMul(a3,13);
        s[c*4+2] := GMul(a0,13) xor GMul(a1,9)  xor GMul(a2,14) xor GMul(a3,11);
        s[c*4+3] := GMul(a0,11) xor GMul(a1,13) xor GMul(a2,9)  xor GMul(a3,14);
      end;
  end;
  for i := 0 to 15 do B[i] := s[i];
end;

// CBC decrypt. If StripIV, the first 16 bytes of Data are the IV (PDF object
// convention); otherwise IV is supplied. PKCS#7 padding removed when StripPad.
function AESDecryptCBC(const Key, Data, IVin: TPdfBytes; StripIV, StripPad: Boolean): TPdfBytes;
var aes: TAES;
  nb, i, b, off, padv: Integer;
    prev, cur, blk: array[0..15] of Byte;
begin
  SetLength(Result, 0);
  aes.Init(Key);
  if StripIV then
  begin
    if Length(Data) < 16 then Exit;
    for i := 0 to 15 do prev[i] := Data[i];
    off := 16;
  end
  else
  begin
    for i := 0 to 15 do if i < Length(IVin) then prev[i] := IVin[i] else prev[i] := 0;
    off := 0;
  end;
  nb := (Length(Data) - off) div 16;
  if nb <= 0 then Exit;
  SetLength(Result, nb*16);
  for i := 0 to nb-1 do
  begin
    for b := 0 to 15 do cur[b] := Data[off + i*16 + b];
    blk := cur;
    aes.DecryptBlock(blk);
    for b := 0 to 15 do Result[i*16+b] := blk[b] xor prev[b];
    prev := cur;
  end;
  if StripPad and (Length(Result) > 0) then
  begin
    padv := Result[High(Result)];
    if (padv >= 1) and (padv <= 16) and (padv <= Length(Result)) then
      SetLength(Result, Length(Result) - padv);
  end;
end;

// CBC encrypt, no padding (data length must be a multiple of 16). Used by R6.
function AESEncryptCBCNoPad(const Key, IV, Data: TPdfBytes): TPdfBytes;
var aes: TAES;
  nb, i, b: Integer;
  prev, blk: array[0..15] of Byte;
begin
  aes.Init(Key);
  for i := 0 to 15 do if i < Length(IV) then prev[i] := IV[i] else prev[i] := 0;
  nb := Length(Data) div 16;
  SetLength(Result, nb*16);
  for i := 0 to nb-1 do
  begin
    for b := 0 to 15 do blk[b] := Data[i*16+b] xor prev[b];
    aes.EncryptBlock(blk);
    for b := 0 to 15 do Result[i*16+b] := blk[b];
    prev := blk;
  end;
end;

// NB: unit names collide with the function names, so qualify as unit.function.
function AESBlockEncrypt(const Key, Block: TPdfBytes): TPdfBytes;
var aes: TAES;
  b: array[0..15] of Byte;
  i: Integer;
begin
  aes.Init(Key);
  for i := 0 to 15 do b[i] := Block[i];
  aes.EncryptBlock(b);
  SetLength(Result, 16);
  for i := 0 to 15 do Result[i] := b[i];
end;

function AESBlockDecrypt(const Key, Block: TPdfBytes): TPdfBytes;
var aes: TAES;
  b: array[0..15] of Byte;
  i: Integer;
begin
  aes.Init(Key);
  for i := 0 to 15 do b[i] := Block[i];
  aes.DecryptBlock(b);
  SetLength(Result, 16);
  for i := 0 to 15 do Result[i] := b[i];
end;

function SHA256B(const D: TPdfBytes): TPdfBytes;
begin
  if Length(D) = 0 then Result := SHA256.SHA256(nil, 0) else Result := SHA256.SHA256(@D[0], Length(D));
end;
function SHA384B(const D: TPdfBytes): TPdfBytes;
begin
  if Length(D) = 0 then Result := SHA384.SHA384(nil, 0) else Result := SHA384.SHA384(@D[0], Length(D));
end;
function SHA512B(const D: TPdfBytes): TPdfBytes;
begin
  if Length(D) = 0 then Result := SHA512.SHA512(nil, 0) else Result := SHA512.SHA512(@D[0], Length(D));
end;

// Algorithm 2.B hash (R6) / single SHA-256 (R5).
function Hash2B(const Pwd, Salt, UData: TPdfBytes; R: Integer): TPdfBytes;
var K, K1, E, base, key16, iv16: TPdfBytes;
    round, i, j, m, sum: Integer;
    elast: Byte;
begin
  K := SHA256B(BCat(BCat(Pwd, Salt), UData));
  if R < 6 then begin
    Result := Slice(K, 0, 32);
    Exit;
  end;
  round := 0;
  repeat
    base := BCat(BCat(Pwd, K), UData);
    SetLength(K1, Length(base) * 64);
    for i := 0 to 63 do Move(base[0], K1[i*Length(base)], Length(base));
    key16 := Slice(K, 0, 16);
    iv16  := Slice(K, 16, 16);
    E := AESEncryptCBCNoPad(key16, iv16, K1);
    sum := 0;
    for i := 0 to 15 do sum := sum + E[i];
    m := sum mod 3;
    case m of
      0: K := SHA256B(E);
      1: K := SHA384B(E);
      2: K := SHA512B(E);
    end;
    Inc(round);
    elast := E[High(E)];
  until (round >= 64) and (elast <= round - 32);
  Result := Slice(K, 0, 32);
end;

// =-=-=-=-=-=-=-=-=-=-─ security handler =-=-=-=-=-=-=-=-=-=-─
function TPdfSecurityHandler.ComputeKeyRC4(const Pwd: TPdfBytes): TPdfBytes;
var buf: TPdfBytes;
  dig: TPdfBytes;
  i: Integer;
  up: Cardinal;
begin
  buf := PadPwd(Pwd);
  buf := BCat(buf, Slice(FO, 0, 32));
  up := Cardinal(FP);
  SetLength(dig, 4);
  dig[0] := Byte(up);
  dig[1] := Byte(up shr 8);
  dig[2] := Byte(up shr 16);
  dig[3] := Byte(up shr 24);
  buf := BCat(buf, dig);
  buf := BCat(buf, FID);
  if (R >= 4) and (not FEncMeta) then
  begin
    SetLength(dig, 4);
    dig[0]:=$FF;
    dig[1]:=$FF;
    dig[2]:=$FF;
    dig[3]:=$FF;
    buf := BCat(buf, dig);
  end;
  dig := MD5OfBytes(buf, Length(buf));
  if R >= 3 then
    for i := 1 to 50 do dig := MD5OfBytes(dig, FKeyLen);
  Result := Slice(dig, 0, FKeyLen);
end;

function TPdfSecurityHandler.AuthUserRC4(const Pwd: TPdfBytes): Boolean;
var key, x, tmp, h: TPdfBytes;
  i, j: Integer;
begin
  key := ComputeKeyRC4(Pwd);
  if R = 2 then
  begin
    SetLength(tmp, 32);
    Move(PAD[0], tmp[0], 32);
    x := RC4Crypt(key, tmp);
    Result := SameBytes(x, FU, 32);
  end
  else
  begin
    SetLength(tmp, 32);
    Move(PAD[0], tmp[0], 32);
    h := MD5OfBytes(BCat(tmp, FID), -1);
    x := RC4Crypt(key, h);
    for i := 1 to 19 do
    begin
      SetLength(tmp, Length(key));
      for j := 0 to High(key) do tmp[j] := key[j] xor Byte(i);
      x := RC4Crypt(tmp, x);
    end;
    Result := SameBytes(x, FU, 16);
  end;
  if Result then FFileKey := key;
end;

function TPdfSecurityHandler.AuthOwnerRC4(const Pwd: TPdfBytes): Boolean;
var dig, rc4key, x, tmp, userpw: TPdfBytes;
  i, j: Integer;
begin
  dig := MD5OfBytes(PadPwd(Pwd), 32);
  if R >= 3 then for i := 1 to 50 do dig := MD5OfBytes(dig, FKeyLen);
  rc4key := Slice(dig, 0, FKeyLen);
  if R = 2 then
    userpw := RC4Crypt(rc4key, Slice(FO, 0, 32))
  else
  begin
    x := Slice(FO, 0, 32);
    for i := 19 downto 0 do
    begin
      SetLength(tmp, FKeyLen);
      for j := 0 to FKeyLen-1 do tmp[j] := rc4key[j] xor Byte(i);
      x := RC4Crypt(tmp, x);
    end;
    userpw := x;
  end;
  Result := AuthUserRC4(userpw);
end;

function TPdfSecurityHandler.AuthUserV5(const Pwd: TPdfBytes): Boolean;
var h, ik: TPdfBytes;
  zero: TPdfBytes;
begin
  h := Hash2B(Pwd, Slice(FU, 32, 8), nil, R);
  Result := SameBytes(h, Slice(FU, 0, 32), 32);
  if Result then
  begin
    ik := Hash2B(Pwd, Slice(FU, 40, 8), nil, R);
    SetLength(zero, 16);
    FFileKey := AESDecryptCBC(ik, FUE, zero, False, False);  // IV=0, no pad → 32 bytes
  end;
end;

function TPdfSecurityHandler.AuthOwnerV5(const Pwd: TPdfBytes): Boolean;
var h, ik, u48, zero: TPdfBytes;
begin
  u48 := Slice(FU, 0, 48);
  h := Hash2B(Pwd, BCat(Slice(FO, 32, 8), u48), u48, R);  // salt=O[32..39], udata=U(48)
  Result := SameBytes(h, Slice(FO, 0, 32), 32);
  if Result then
  begin
    ik := Hash2B(Pwd, BCat(Slice(FO, 40, 8), u48), u48, R);
    SetLength(zero, 16);
    FFileKey := AESDecryptCBC(ik, FOE, zero, False, False);
  end;
end;

function TPdfSecurityHandler.Setup(AR, AV, ALengthBits: Integer;
  const AO, AU, AOE, AUE, AID: TPdfBytes; AP: LongInt; AEncMeta: Boolean;
  AStm, AStr: TPdfCryptMethod; const Password: AnsiString): Boolean;
var pw: TPdfBytes;
begin
  R := AR;
  V := AV;
  FO := AO;
  FU := AU;
  FOE := AOE;
  FUE := AUE;
  FID := AID;
  FP := AP;
  FEncMeta := AEncMeta;
  StmMethod := AStm;
  StrMethod := AStr;
  pw := StrToBytes(Password);
  if V >= 5 then
  begin
    FKeyLen := 32;
    Result := AuthUserV5(pw);
    if not Result then Result := AuthOwnerV5(pw);
  end
  else
  begin
    if V <= 1 then FKeyLen := 5
    else FKeyLen := ALengthBits div 8;
    if FKeyLen <= 0 then FKeyLen := 5;
    if FKeyLen > 16 then FKeyLen := 16;
    Result := AuthUserRC4(pw);
    if not Result then Result := AuthOwnerRC4(pw);
  end;
  Authenticated := Result;
end;

// Per-object key for RC4/AESV2 (Algorithm 1).
function TPdfSecurityHandler.ObjKey(ObjNum, Gen: Integer; AES: Boolean): TPdfBytes;
var buf, dig: TPdfBytes;
  n, extra: Integer;
begin
  n := FKeyLen;
  if AES then extra := 4 else extra := 0;
  SetLength(buf, n + 5 + extra);
  Move(FFileKey[0], buf[0], n);
  buf[n]   := Byte(ObjNum);
  buf[n+1] := Byte(ObjNum shr 8);
  buf[n+2] := Byte(ObjNum shr 16);
  buf[n+3] := Byte(Gen);
  buf[n+4] := Byte(Gen shr 8);
  if AES then begin
    buf[n+5]:=$73;
    buf[n+6]:=$41;
    buf[n+7]:=$6C;
    buf[n+8]:=$54;
  end;  // "sAlT"
  dig := MD5OfBytes(buf, Length(buf));
  if n + 5 < 16 then Result := Slice(dig, 0, n + 5) else Result := Slice(dig, 0, 16);
end;

function TPdfSecurityHandler.Decrypt(const Data: TPdfBytes; ObjNum, Gen: Integer; IsString: Boolean): TPdfBytes;
var m: TPdfCryptMethod;
begin
  if IsString then m := StrMethod else m := StmMethod;
  case m of
    cmIdentity: Result := Copy(Data);
    cmAESV3:    Result := AESDecryptCBC(FFileKey, Data, nil, True, True);
    cmRC4:      Result := RC4Crypt(ObjKey(ObjNum, Gen, False), Data);
    cmAESV2:    Result := AESDecryptCBC(ObjKey(ObjNum, Gen, True), Data, nil, True, True);
  else
    Result := Copy(Data);
  end;
end;

end.
