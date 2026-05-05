Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @"
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;

public static class MockupMaker {
  static GraphicsPath RoundedRect(float x,float y,float w,float h,float r){
    var p=new GraphicsPath();
    float d=r*2;
    p.AddArc(x,y,d,d,180,90);
    p.AddArc(x+w-d,y,d,d,270,90);
    p.AddArc(x+w-d,y+h-d,d,d,0,90);
    p.AddArc(x,y+h-d,d,d,90,90);
    p.CloseFigure();
    return p;
  }

  static void DrawBackground(Graphics g,int mode){
    Color c1,c2;
    switch(mode){
      case 0: c1=Color.FromArgb(10,18,40); c2=Color.FromArgb(34,66,120); break;
      case 1: c1=Color.FromArgb(18,14,40); c2=Color.FromArgb(86,42,132); break;
      case 2: c1=Color.FromArgb(8,28,44); c2=Color.FromArgb(20,108,128); break;
      case 3: c1=Color.FromArgb(17,27,58); c2=Color.FromArgb(74,91,153); break;
      case 4: c1=Color.FromArgb(12,32,54); c2=Color.FromArgb(42,118,166); break;
      default: c1=Color.FromArgb(22,22,42); c2=Color.FromArgb(76,69,140); break;
    }
    using(var b=new LinearGradientBrush(new Rectangle(0,0,1024,500), c1,c2,35f)){
      g.FillRectangle(b,0,0,1024,500);
    }
    var rng = new Random(1337+mode*17);
    for(int i=0;i<70;i++){
      int x=rng.Next(0,1024); int y=rng.Next(0,500);
      int s=rng.Next(1,3); int a=rng.Next(30,90);
      using(var sb=new SolidBrush(Color.FromArgb(a,255,255,255))) g.FillEllipse(sb,x,y,s,s);
    }
  }

  static void DrawCard(Graphics g, string imgPath, float x,float y,float w,float h, bool center, bool phone, string label){
    using(var sh=RoundedRect(x+6,y+8,w,h,22f))
    using(var sb=new SolidBrush(Color.FromArgb(center?90:55,0,0,0)))
      g.FillPath(sb,sh);

    using(var fr=RoundedRect(x,y,w,h,22f)){
      using(var fb=new SolidBrush(Color.FromArgb(19,28,49))) g.FillPath(fb,fr);
      using(var pen=new Pen(center?Color.FromArgb(245,228,176):Color.FromArgb(212,220,240), center?3f:2f)) g.DrawPath(pen,fr);
    }

    float m = phone ? 14f : 12f;
    float ix=x+m, iy=y+m, iw=w-2*m, ih=h-2*m;
    using(var inner=RoundedRect(ix,iy,iw,ih,12f)){
      using(var ib=new SolidBrush(Color.FromArgb(8,10,14))) g.FillPath(ib,inner);
      using(var img=Image.FromFile(imgPath)){
        float scale = Math.Min(iw/img.Width, ih/img.Height); // contain, no crop
        float dw = img.Width*scale, dh = img.Height*scale;
        float dx = ix + (iw-dw)/2f, dy = iy + (ih-dh)/2f;
        Region old = g.Clip;
        g.SetClip(inner);
        g.DrawImage(img, dx, dy, dw, dh);
        g.Clip = old;
      }
      using(var lb=new SolidBrush(Color.FromArgb(205,255,255,255)))
      using(var f=new Font("Segoe UI", center?10f:9f, FontStyle.Bold))
        g.DrawString(label,f,lb,ix+8,iy+8);
    }
  }

  public static void Create(string outputPath, string left, string center, string right, bool phone, int mode, string subtitle){
    using(var bmp=new Bitmap(1024,500))
    using(var g=Graphics.FromImage(bmp)){
      g.SmoothingMode=SmoothingMode.AntiAlias;
      g.InterpolationMode=InterpolationMode.HighQualityBicubic;
      g.PixelOffsetMode=PixelOffsetMode.HighQuality;
      g.CompositingQuality=CompositingQuality.HighQuality;

      DrawBackground(g,mode);
      if(phone){
        DrawCard(g,left,130,70,220,360,false,true,"Android");
        DrawCard(g,center,380,40,264,420,true,true,"Stellar Lens");
        DrawCard(g,right,674,70,220,360,false,true,"APOD");
      } else {
        DrawCard(g,left,56,132,290,210,false,false,"Desktop");
        DrawCard(g,center,344,100,336,252,true,false,"Stellar Lens");
        DrawCard(g,right,678,132,290,210,false,false,"Windows");
      }

      using(var tb=new SolidBrush(Color.FromArgb(220,255,255,255)))
      using(var tf=new Font("Segoe UI",21f,FontStyle.Bold))
      using(var sf=new Font("Segoe UI",10f,FontStyle.Regular)){
        g.DrawString("Stellar Lens",tf,tb,28,24);
        g.DrawString(subtitle,sf,tb,30,58);
      }

      string tmp = outputPath + ".new";
      bmp.Save(tmp, System.Drawing.Imaging.ImageFormat.Png);
      File.WriteAllBytes(outputPath, File.ReadAllBytes(tmp));
      File.Delete(tmp);
    }
  }
}
"@

$android = @(
  'screenshots/android_SS/Screenshot_1777727594.png',
  'screenshots/android_SS/Screenshot_1777731968.png',
  'screenshots/android_SS/Screenshot_1777732004.png'
)
$windows = @(
  'screenshots/windows_SS/Screenshot 2026-05-03 003100.png',
  'screenshots/windows_SS/Screenshot 2026-05-03 003231.png',
  'screenshots/windows_SS/Screenshot 2026-05-03 003308.png'
)

[MockupMaker]::Create('mockups/phone_mockup_01.png',$android[1],$android[0],$android[2],$true,0,'Daily APOD • Carousel Preview')
[MockupMaker]::Create('mockups/phone_mockup_02.png',$android[2],$android[1],$android[0],$true,1,'Immersive Mobile Space Feed')
[MockupMaker]::Create('mockups/phone_mockup_03.png',$android[0],$android[2],$android[1],$true,2,'Explore NASA Photos Daily')

[MockupMaker]::Create('mockups/tablet_mockup_01.png',$windows[1],$windows[0],$windows[2],$false,3,'Desktop Experience • Carousel Preview')
[MockupMaker]::Create('mockups/tablet_mockup_02.png',$windows[2],$windows[1],$windows[0],$false,4,'Slideshow, Media, Wallpaper')
[MockupMaker]::Create('mockups/tablet_mockup_03.png',$windows[0],$windows[2],$windows[1],$false,5,'Wide Layout APOD Browser')

Get-ChildItem mockups -File -Filter *.tmp | Remove-Item -Force -ErrorAction SilentlyContinue
Write-Host 'recreated_from_screenshots'
