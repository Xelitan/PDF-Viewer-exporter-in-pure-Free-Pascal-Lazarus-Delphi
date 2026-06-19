unit PdfGraphics;
{$mode delphi}

//PDF Viewer in Pascal
//Author: www.xelitan.com
//License: GNU/GPL
//Commercial licenses are available.
//=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=-=
interface
uses SysUtils, Classes, Contnrs, PdfTypes;

type
  TPdfGraphicsState = class
  public
    CTM: TPdfMatrix;
    TextMatrix: TPdfMatrix;
    TextLineMatrix: TPdfMatrix;
    FontName: string;
    FontSize: Double;
    CharSpacing: Double;
    WordSpacing: Double;
    HorizontalScaling: Double;
    Leading: Double;
    TextRise: Double;
    TextRenderMode: Integer;  // Tr: 0 fill,1 stroke,2 fill+stroke,3 invisible,4-7 +clip
    // Non-stroking (fill) colour — 0..1 per channel, default black.
    FillR, FillG, FillB: Double;
    // Stroking colour — 0..1 per channel, default black.
    StrokeR, StrokeG, StrokeB: Double;
    LineWidth: Double;  // user-space line width (default 1)
    // Active clip rectangle in page space (intersection of all clips in effect).
    HasClip: Boolean;
    ClipX1, ClipY1, ClipX2, ClipY2: Double;
    // Active ExtGState soft mask (a TPdfSoftMask, owned by the page) or nil.
    // Elements painted while this is set are composited through the mask.
    SoftMask: TObject;
    // Current fill/stroke colour space objects set by cs/CS (the resolved
    // ColorSpace object: a Separation/DeviceN/ICCBased/Lab array, owned by the
    // document object tree). nil = a plain device space; then sc/scn interpret
    // operands by count (1=gray, 3=rgb, 4=cmyk). Cloned as plain references.
    FillCSObj: TObject;
    StrokeCSObj: TObject;
    // Active non-rectangular clip paths (TPdfClipPath refs, owned by the page).
    // The effective clip is the intersection of HasClip's rect and all of these.
    ClipPaths: array of TObject;
    constructor Create;
    function Clone: TPdfGraphicsState;
  end;

  TPdfGraphicsStack = class
  private
    FStack: TObjectList;
  public
    Current: TPdfGraphicsState;
    constructor Create;
    destructor Destroy;
    override;
    procedure Save;
    procedure Restore;
  end;

implementation

constructor TPdfGraphicsState.Create;
begin
  inherited Create;
  CTM := PdfIdentityMatrix;
  TextMatrix := PdfIdentityMatrix;
  TextLineMatrix := PdfIdentityMatrix;
  HorizontalScaling := 100;
  LineWidth := 1;
end;

function TPdfGraphicsState.Clone: TPdfGraphicsState;
begin
  Result := TPdfGraphicsState.Create;
  Result.CTM := CTM;
  Result.TextMatrix := TextMatrix;
  Result.TextLineMatrix := TextLineMatrix;
  Result.FontName := FontName;
  Result.FontSize := FontSize;
  Result.CharSpacing := CharSpacing;
  Result.WordSpacing := WordSpacing;
  Result.HorizontalScaling := HorizontalScaling;
  Result.Leading := Leading;
  Result.TextRise := TextRise;
  Result.TextRenderMode := TextRenderMode;
  Result.FillR := FillR;
  Result.FillG := FillG;
  Result.FillB := FillB;
  Result.StrokeR := StrokeR;
  Result.StrokeG := StrokeG;
  Result.StrokeB := StrokeB;
  Result.LineWidth := LineWidth;
  Result.HasClip := HasClip;
  Result.ClipX1 := ClipX1;
  Result.ClipY1 := ClipY1;
  Result.ClipX2 := ClipX2;
  Result.ClipY2 := ClipY2;
  Result.SoftMask := SoftMask;
  Result.FillCSObj := FillCSObj;
  Result.StrokeCSObj := StrokeCSObj;
  Result.ClipPaths := Copy(ClipPaths);  // copy refs; TPdfClipPath objects owned by page
end;

constructor TPdfGraphicsStack.Create;
begin
  inherited Create;
  FStack := TObjectList.Create(True);
  Current := TPdfGraphicsState.Create;
end;
destructor TPdfGraphicsStack.Destroy;
begin
  Current.Free;
  FStack.Free;
  inherited Destroy;
end;
procedure TPdfGraphicsStack.Save;
begin
  FStack.Add(Current.Clone);
end;
procedure TPdfGraphicsStack.Restore;
begin
  if FStack.Count = 0 then Exit;
  Current.Free;
  FStack.OwnsObjects := False;
  Current := TPdfGraphicsState(FStack.Last);
  FStack.Delete(FStack.Count - 1);
  FStack.OwnsObjects := True;
end;

end.
