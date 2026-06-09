unit PdfJpeg;

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=

//Minimal JPEG decoder built directly on pasjpeg (jpeglib).
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
//The stock FPImage/LCL reader (TFPReaderJPEG) mishandles CMYK and Adobe
//YCCK JPEGs: it applies a crude "remove minimum" approximation and ignores
//the Adobe APP14 inversion convention, so CMYK images from tools like
//Photoshop/Acrobat come out looking like colour negatives. PDFs lean heavily
//on DeviceCMYK DCTDecode images, so we decode here to raw component samples
//and run the proper, Adobe-aware CMYK -> RGB conversion ourselves.

{$mode delphi}

interface

uses
  SysUtils, Classes, PdfTypes,
  JPEGLib, JdAPImin, JdAPIstd, JDataSrc, JmoreCfg;

// Decode a baseline/progressive JPEG into packed 24-bit RGB (R,G,B per pixel).
// Returns False if the data is not a usable JPEG. Handles grayscale, RGB,
// CMYK and YCCK (Adobe) source colour spaces.
function DecodeJpegToRGB(const Data: TPdfBytes; out W, H: Integer; out RGB: TPdfBytes): Boolean;

implementation

procedure PdfJpegErrorExit(CurInfo: j_common_ptr);
far;
begin
  raise Exception.Create('JPEG decode error');
end;

procedure PdfJpegEmitMessage(CurInfo: j_common_ptr; msg_level: Integer);
far;
begin
end;

procedure PdfJpegOutputMessage(CurInfo: j_common_ptr);
far;
begin
end;

procedure PdfJpegFormatMessage(CurInfo: j_common_ptr; var buffer: string);
far;
begin
end;

procedure PdfJpegResetErrorMgr(CurInfo: j_common_ptr);
far;
begin
  if CurInfo = nil then Exit;
  CurInfo^.err^.num_warnings := 0;
  CurInfo^.err^.msg_code := 0;
end;

function DecodeJpegToRGB(const Data: TPdfBytes; out W, H: Integer; out RGB: TPdfBytes): Boolean;
var
  Info: jpeg_decompress_struct;
  Err: jpeg_error_mgr;
  Stream: TMemoryStream;
  SampArray: JSAMPARRAY;
  SampRow: JSAMPROW;
  IsCMYK, IsAdobe: Boolean;
  X, Y, Comps, RowBytes, DstRow: Integer;
  sC, sM, sY, sK: Integer;
begin
  Result := False;
  W := 0;
  H := 0;
  RGB := nil;
  if Length(Data) < 4 then Exit;

  Stream := TMemoryStream.Create;
  SampArray := nil;
  SampRow := nil;
  FillChar(Info, SizeOf(Info), 0);
  FillChar(Err, SizeOf(Err), 0);
  Err.error_exit     := @PdfJpegErrorExit;
  Err.emit_message   := @PdfJpegEmitMessage;
  Err.output_message := @PdfJpegOutputMessage;
  Err.format_message := @PdfJpegFormatMessage;
  Err.reset_error_mgr := @PdfJpegResetErrorMgr;
  try
    try
      Stream.WriteBuffer(Data[0], Length(Data));
      Stream.Position := 0;

      Info.err := @Err;
      jpeg_CreateDecompress(@Info, JPEG_LIB_VERSION, SizeOf(Info));
      try
        jpeg_stdio_src(@Info, @Stream);
        jpeg_read_header(@Info, True);

        IsCMYK  := Info.jpeg_color_space in [JCS_CMYK, JCS_YCCK];
        if IsCMYK then Info.out_color_space := JCS_CMYK          // jpeglib turns YCCK into CMYK
        else if Info.jpeg_color_space = JCS_GRAYSCALE then Info.out_color_space := JCS_GRAYSCALE
        else Info.out_color_space := JCS_RGB;

        jpeg_start_decompress(@Info);
        W := Info.output_width;
        H := Info.output_height;
        Comps := Info.output_components;
        IsAdobe := Info.saw_Adobe_marker;
        if (W <= 0) or (H <= 0) or (Comps <= 0) then Exit;

        SetLength(RGB, W * H * 3);
        RowBytes := W * Comps;
        GetMem(SampArray, SizeOf(JSAMPROW));
        GetMem(SampRow, RowBytes);
        SampArray^[0] := SampRow;

        Y := 0;
        while Info.output_scanline < Info.output_height do
        begin
          if jpeg_read_scanlines(@Info, SampArray, 1) < 1 then Break;
          DstRow := Y * W * 3;
          if IsCMYK then
            for X := 0 to W - 1 do
            begin
              sC := SampRow^[X*4+0];
              sM := SampRow^[X*4+1];
              sY := SampRow^[X*4+2];
              sK := SampRow^[X*4+3];
              // pasjpeg's YCCK/CMYK colour conversion already undoes the Adobe
              // inversion, so the samples are plain CMYK here. Standard
              // CMYK -> RGB: R = (1-C)(1-K), etc. (Verified against reference
              // renders — inverting again produced colour-negative images.)
              RGB[DstRow + X*3 + 0] := Byte(((255 - sC) * (255 - sK)) div 255);
              RGB[DstRow + X*3 + 1] := Byte(((255 - sM) * (255 - sK)) div 255);
              RGB[DstRow + X*3 + 2] := Byte(((255 - sY) * (255 - sK)) div 255);
            end
          else if Comps = 1 then
            for X := 0 to W - 1 do
            begin
              RGB[DstRow + X*3 + 0] := SampRow^[X];
              RGB[DstRow + X*3 + 1] := SampRow^[X];
              RGB[DstRow + X*3 + 2] := SampRow^[X];
            end
          else
            for X := 0 to W - 1 do
            begin
              RGB[DstRow + X*3 + 0] := SampRow^[X*Comps+0];
              RGB[DstRow + X*3 + 1] := SampRow^[X*Comps+1];
              RGB[DstRow + X*3 + 2] := SampRow^[X*Comps+2];
            end;
          Inc(Y);
        end;
        Result := (Y > 0);
      finally
        jpeg_Destroy_Decompress(@Info);
      end;
    except
      Result := False;
    end;
  finally
    if Assigned(SampRow) then FreeMem(SampRow);
    if Assigned(SampArray) then FreeMem(SampArray);
    Stream.Free;
  end;
end;

end.
