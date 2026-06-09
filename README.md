# License

GNU/GPL. Commercial licenses available, starting at $100 (single developer, up to 5 programs).

# Usage examples

## Just showing a PDF:
```
type
  TForm1 = class(TForm)
...
  public
    PDF: TXelPDF;
  end;
...
procedure TForm1.FormCreate(Sender: TObject);
begin
  PDF := TXelPDF.Create(Form1);
  Pdf.Parent := Form1;
  Pdf.Align := alClient;
  Pdf.LoadFromFile('test.pdf');
end;

procedure TForm1.FormClose(Sender: TObject; var CloseAction: TCloseAction);
begin
  Pdf.Free;
end;  
```

## Converting .TXT to .PDF
```
PDF := TXelPDF.Create(Form1);
Pdf.LoadFromFile('input.txt');
Pdf.Document.SaveToFile('txt.pdf');
```

## Exporting an embedded font:
```
TotalFonts := PDF.Document.CountFonts; //count fonts in the PDF
PDF.Document.ExportFont(5, 'out.otf'); //5 is the number of the font
```

## Exporting a JPEG or another bitmap:
```
//images that are embedded as JPEGs in the PDF- no recompression, except CMYK->RGB
Total := Doc.JpegsCount(PageNumber);
Doc.ExportJpeg(PageNumber, JpegNumber, 'out.jpg');
```
Other images:
```
//images that are embedded in other formats in the PDF- conversion to PNG
Total := Doc.ImagesCount(PageNumber);
Doc.ExportImage(PageNumber, ImageNumber, 'out.png');
```

## Exporting vector images to SVG
```
Total := Doc.VectorGroupsCount(PageNumber);
Doc.ExportVectorGroup(PageNumber, ImageNumber, 'out.svg');
```

## Drawing a rectangle:

```
Doc.DrawRect(0, 50, 600, 200, 80, clRed); //PageNum, Left, Top, Width, Height, Color
```

## Rendering to image
```
Doc.RenderPageToPng(PageNumber, 'out.png');
```

## Insert another PDF between pages of current PDF

```
F := TFileStream.Create('another.pdf', fmOpenRead);
Doc.ImportPDF(F, 0, 0, 0);
```

## Insert a blank page or remove a page:

```
Doc.RemovePage(PageIndex);
Doc.AddPage(Width, Height);
```

## Load or save document to file or stream
```
Doc.SaveToStream(Str: TStream);
Doc.SaveToFile('output.pdf');
```
## Insert a JPEG image into a PDF:
```
Doc.AddJpegImage(PageIndex, JpegBytes, Left, Top, Width, Height);
```
## Insert some text into a PDF:
```                           
FontRes := Doc.AddFont(FontName, FontSize);
Doc.AddText(PageIndex, 'Test Here', Left, Top, FontRes);
```

## Extract text to a file
```    
Doc.ExtractTextToFile(PageIndex, 'output.txt');
```
