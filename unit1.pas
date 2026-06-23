unit Unit1;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Types, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  Menus, PrintersDlgs, Interfaces, PdfTypes, PdfParser, PdfBitmapRenderer, XelPDF;

type

  // Ctrl + mouse-wheel zoom, handled in the application (a TXelPDF descendant
  // declared here) so the reusable TXelPDF control itself is left untouched.
  TZoomPDF = class(TXelPDF)
  protected
    function DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
                          MousePos: TPoint): Boolean; override;
  end;

  { TForm1 }

  TForm1 = class(TForm)
    MainMenu1: TMainMenu;
    MenuItem1: TMenuItem;
    MenuItem11: TMenuItem;
    MenuItem12: TMenuItem;
    MenuItem13: TMenuItem;
    MenuItem14: TMenuItem;
    MenuItem15: TMenuItem;
    MenuItem16: TMenuItem;
    MenuItem17: TMenuItem;
    MenuItem18: TMenuItem;
    MenuItem19: TMenuItem;
    MenuItem7: TMenuItem;
    MenuItemPrint: TMenuItem;
    SelectDirectoryDialog1: TSelectDirectoryDialog;
    Separator3: TMenuItem;
    Separator2: TMenuItem;
    MenuItem2: TMenuItem;
    MenuItem3: TMenuItem;
    MenuItem4: TMenuItem;
    MenuItem5: TMenuItem;
    MenuItem6: TMenuItem;
    MenuItem8: TMenuItem;
    MenuItem9: TMenuItem;
    SaveDialog2: TSaveDialog;
    Separator1: TMenuItem;
    OpenDialog1: TOpenDialog;
    SaveDialog1: TSaveDialog;
    procedure Button1Click(Sender: TObject);
    procedure FormClose(Sender: TObject; var CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure MenuItem10Click(Sender: TObject);
    procedure MenuItem12Click(Sender: TObject);
    procedure MenuItem13Click(Sender: TObject);
    procedure MenuItem14Click(Sender: TObject);
    procedure MenuItem15Click(Sender: TObject);
    procedure MenuItem16Click(Sender: TObject);
    procedure MenuItem18Click(Sender: TObject);
    procedure MenuItem19Click(Sender: TObject);
    procedure MenuItem2Click(Sender: TObject);
    procedure MenuItem3Click(Sender: TObject);
    procedure MenuItem4Click(Sender: TObject);
    procedure MenuItem5Click(Sender: TObject);
    procedure MenuItem7Click(Sender: TObject);
    procedure MenuItem8Click(Sender: TObject);
    procedure MenuItem9Click(Sender: TObject);
    procedure MenuItemPrintClick(Sender: TObject);
  private
    FSearchPanel: TPanel;
    FSearchEdit : TEdit;
    FCaseChk    : TCheckBox;
    FFindBtn    : TButton;
    FLastQuery  : string;
    FLastCase   : Boolean;
    procedure BuildSearchBar;
    procedure DoFind(Sender: TObject);
    procedure SearchEditKeyPress(Sender: TObject; var Key: Char);
  public
    PDF: TXelPDF;
  end;

var
  Form1: TForm1;

implementation

{$R *.lfm}

{ TZoomPDF }

function TZoomPDF.DoMouseWheel(Shift: TShiftState; WheelDelta: Integer;
  MousePos: TPoint): Boolean;
begin
  if ssCtrl in Shift then
  begin
    // Ctrl + wheel = zoom. Turn off width-fit so the manual zoom persists.
    AutoFit := afNone;
    if WheelDelta > 0 then Scale := Scale * 1.1
    else                   Scale := Scale / 1.1;
    Result := True;
  end
  else
    Result := inherited DoMouseWheel(Shift, WheelDelta, MousePos);  // normal scroll
end;

{ TForm1 }

procedure TForm1.Button1Click(Sender: TObject);
begin
end;

// Build the top search bar (query edit + "Case sensitive" checkbox + Find button)
// entirely in code so no .lfm changes are needed.
procedure TForm1.BuildSearchBar;
begin
  FSearchPanel := TPanel.Create(Self);
  FSearchPanel.Parent     := Self;
  FSearchPanel.Align      := alTop;
  FSearchPanel.Height     := 32;
  FSearchPanel.BevelOuter := bvNone;

  FSearchEdit := TEdit.Create(Self);
  FSearchEdit.Parent     := FSearchPanel;
  FSearchEdit.SetBounds(4, 4, 220, 24);
  FSearchEdit.TextHint   := 'Search text...';
  FSearchEdit.OnKeyPress := @SearchEditKeyPress;

  FCaseChk := TCheckBox.Create(Self);
  FCaseChk.Parent  := FSearchPanel;
  FCaseChk.SetBounds(232, 7, 120, 20);
  FCaseChk.Caption := 'Case sensitive';

  FFindBtn := TButton.Create(Self);
  FFindBtn.Parent  := FSearchPanel;
  FFindBtn.SetBounds(356, 4, 80, 24);
  FFindBtn.Caption := 'Find';
  FFindBtn.OnClick := @DoFind;
end;

procedure TForm1.DoFind(Sender: TObject);
var n: Integer;
begin
  if FSearchEdit.Text = '' then Exit;
  // New query (or toggled case) -> search; same query -> jump to the next match.
  if (FSearchEdit.Text <> FLastQuery) or (FCaseChk.Checked <> FLastCase) then
  begin
    FLastQuery := FSearchEdit.Text;
    FLastCase  := FCaseChk.Checked;
    n := Pdf.Search(FLastQuery, FLastCase);
    if n = 0 then
      ShowMessage('Not found: ' + FLastQuery)
    else
      Caption := Format('Xelitan PDF  -  %d match(es) for "%s"', [n, FLastQuery]);
  end
  else
    Pdf.SearchNext;
end;

procedure TForm1.SearchEditKeyPress(Sender: TObject; var Key: Char);
begin
  if Key = #13 then
  begin
    Key := #0;        // swallow Enter (avoids the warning beep)
    DoFind(Sender);
  end;
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  Pdf.Free;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  BuildSearchBar;   // top bar (created first so the viewer fills the area below)

  PDF := TZoomPDF.Create(Self);   // TZoomPDF adds Ctrl+wheel zoom
  Pdf.Parent  := Self;
  Pdf.Align   := alClient;
  Pdf.AutoFit := afWidth;

  Pdf.LoadFromFile('test2.pdf');
  Pdf.RefreshView;  // reflect the freshly loaded document
end;

procedure TForm1.MenuItem10Click(Sender: TObject);
begin

end;

procedure TForm1.MenuItem12Click(Sender: TObject);
begin
  Pdf.Document.DrawRect(Pdf.CurrentPage, 20, 20, 200, 200, clRed);
  Pdf.RefreshView;
end;

procedure TForm1.MenuItem13Click(Sender: TObject);
var Dlg: TOpenDialog;
    MS : TMemoryStream;
    Data: TPdfBytes;
begin
  Dlg := TOpenDialog.Create(nil);
  try
    Dlg.Filter := 'JPEG images|*.jpg;*.jpeg';
    if not Dlg.Execute then Exit;
    MS := TMemoryStream.Create;
    try
      MS.LoadFromFile(Dlg.FileName);
      SetLength(Data, MS.Size);
      if MS.Size > 0 then Move(MS.Memory^, Data[0], MS.Size);
    finally
      MS.Free;
    end;
    // Place the image at (20,20), 200x200 page units (PDF origin = bottom-left).
    Pdf.Document.AddJpegImage(Pdf.CurrentPage, Data, 20, 20, 200, 200);
    Pdf.RefreshView;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.MenuItem14Click(Sender: TObject);
var FontRes: AnsiString;
begin
  FontRes := Pdf.Document.AddFont('Verdana', 40);
  Pdf.Document.AddText(Pdf.CurrentPage, 'Hello World', 20, 700, FontRes);
  Pdf.RefreshView;
end;

procedure TForm1.MenuItem15Click(Sender: TObject);
begin
  Pdf.Document.RemovePage(Pdf.CurrentPage);
  Pdf.RefreshView;
end;

procedure TForm1.MenuItem16Click(Sender: TObject);
begin
 Pdf.Document.AddPage(200,500);
  Pdf.RefreshView;
end;

procedure TForm1.MenuItem18Click(Sender: TObject);
var i: Integer;
    Dir: String;
begin
  if not SelectDirectoryDialog1.Execute then Exit;
  Dir := ExtractFileDir(SelectDirectoryDialog1.FileName) + '\';

  for i:=0 to Pdf.Document.FontsCount-1 do
    Pdf.Document.ExportFont(i, Dir + IntToStr(i+1) + '.otf');
end;

procedure TForm1.MenuItem19Click(Sender: TObject);
begin
  Pdf.Document.RotateRight(Pdf.CurrentPage);
  Pdf.RefreshView;  // rotation changes the document behind the viewer; rebuild cache
end;

procedure TForm1.MenuItem2Click(Sender: TObject);
begin
  if not OpenDialog1.Execute then Exit;
  Pdf.LoadFromFile(OpenDialog1.Filename);  // viewer load (re-lays out pages)
  Pdf.RefreshView;
  FLastQuery := '';                         // reset search state for the new doc
  Caption := 'Xelitan PDF';
end;

procedure TForm1.MenuItem3Click(Sender: TObject);
begin
  if not SaveDialog1.Execute then Exit;
  Pdf.Document.SaveToFile(SaveDialog1.Filename);
end;

procedure TForm1.MenuItem4Click(Sender: TObject);
begin
  Close;
end;

procedure TForm1.MenuItem5Click(Sender: TObject);
begin
  if not SaveDialog2.Execute then Exit;
  Pdf.Document.ExtractTextToFile(0, SaveDialog2.Filename);
end;

procedure TForm1.MenuItem7Click(Sender: TObject);
begin
  Pdf.Document.RotateLeft(Pdf.CurrentPage);
  Pdf.RefreshView;  // rotation changes the document behind the viewer; rebuild cache
end;

procedure TForm1.MenuItemPrintClick(Sender: TObject);
var Dlg: TPrintDialog;
    PageCount, FromPg, ToPg: Integer;
begin
  if (Pdf.Document = nil) or (Pdf.Document.Pages.Count = 0) then Exit;
  PageCount := Pdf.Document.Pages.Count;
  Dlg := TPrintDialog.Create(nil);
  try
    // Enable the "Pages from..to" box and seed it with the full range.
    Dlg.Options  := Dlg.Options + [poPageNums];
    Dlg.MinPage  := 1;
    Dlg.MaxPage  := PageCount;
    Dlg.FromPage := 1;
    Dlg.ToPage   := PageCount;
    Dlg.PrintRange := prAllPages;
    if not Dlg.Execute then Exit;  // user cancelled / no printer chosen

    // Dialog page numbers are 1-based; TXelPDF.Print expects 0-based, inclusive.
    if Dlg.PrintRange = prPageNums then
    begin
      FromPg := Dlg.FromPage - 1;
      ToPg   := Dlg.ToPage - 1;
    end
    else
    begin
      FromPg := 0;
      ToPg   := PageCount - 1;  // all pages
    end;

    try
      Pdf.Print('PDF Document', FromPg, ToPg);
    except
      on E: Exception do
        MessageDlg('Printing failed', E.Message, mtError, [mbOK], 0);
    end;
  finally
    Dlg.Free;
  end;
end;

procedure TForm1.MenuItem8Click(Sender: TObject);
var TotalJpegs: Integer;
    i: Integer;
    Dir: String;
begin
  if not SelectDirectoryDialog1.Execute then Exit;
  Dir := ExtractFileDir(SelectDirectoryDialog1.FileName) + '\';

  TotalJpegs := Pdf.Document.JpegsCount(Pdf.CurrentPage);

  for i:=0 to TotalJpegs-1 do
    Pdf.Document.ExportJpeg(Pdf.CurrentPage, i, Dir + IntToStr(i+1) + '.jpg');

  for i:=0 to Pdf.Document.ImagesCount(Pdf.CurrentPage)-1 do
    Pdf.Document.ExportImage(Pdf.CurrentPage, i, Dir + IntToStr(i+TotalJpegs) + '.png');

end;

procedure TForm1.MenuItem9Click(Sender: TObject);
var i, cnt: Integer;
    Dir: String;
begin
  cnt := Pdf.Document.VectorsCount(Pdf.CurrentPage);
  if cnt = 0 then
  begin
    ShowMessage('No vector graphics on this page.');
    Exit;
  end;
  if not SelectDirectoryDialog1.Execute then Exit;
  Dir := IncludeTrailingPathDelimiter(SelectDirectoryDialog1.FileName);
  for i := 0 to cnt - 1 do
    Pdf.Document.ExportVector(Pdf.CurrentPage, i, Dir + Format('vector_%d.svg', [i + 1]));
  ShowMessage(Format('Exported %d vector(s) to %s', [cnt, Dir]));
end;

end.

