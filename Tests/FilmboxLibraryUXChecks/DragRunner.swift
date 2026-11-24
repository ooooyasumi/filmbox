import AppKit
@testable import Filmbox
@main @MainActor struct DragChecks {
 static func main() throws {
  _ = NSApplication.shared
  let window = NSWindow(contentRect:NSRect(x:0,y:0,width:240,height:120),styleMask:[.borderless],backing:.buffered,defer:false)
  window.isReleasedWhenClosed=false
  defer { window.close() }
  let a = LibraryDragView(frame:NSRect(x:0,y:0,width:200,height:32))
  let b = LibraryDragView(frame:NSRect(x:0,y:40,width:200,height:32))
  window.contentView!.addSubview(a);window.contentView!.addSubview(b)
  var clicks=0;var moved:UUID?
  a.onClick={clicks+=1};b.onMove={moved=$0}
  func event(_ type:NSEvent.EventType,_ y:CGFloat)->NSEvent { NSEvent.mouseEvent(with:type,location:NSPoint(x:80,y:y),modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1)! }
  a.mouseDown(with:event(.leftMouseDown,10));a.mouseUp(with:event(.leftMouseUp,10))
  guard clicks==1 && moved==nil else {throw NSError(domain:"普通点击",code:1)}
  a.mouseDown(with:event(.leftMouseDown,10));a.mouseDragged(with:event(.leftMouseDragged,50));a.mouseUp(with:event(.leftMouseUp,50))
  guard clicks==1 && moved==a.libraryID else {throw NSError(domain:"拖到目标库",code:1)}
  moved=nil
  a.mouseDown(with:event(.leftMouseDown,10));a.mouseDragged(with:event(.leftMouseDragged,100));a.mouseUp(with:event(.leftMouseUp,100))
  guard clicks==1 && moved==nil else {throw NSError(domain:"空白处取消",code:1)}
  print("3项原生资源库手势检查通过；单击、跨行排序、空白处取消，不向桌面注入事件")
 }
}
