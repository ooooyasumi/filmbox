package com.filmbox.qa;

import android.app.Activity;
import android.app.Instrumentation;
import android.content.ContentValues;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.net.Uri;
import android.os.Bundle;
import android.os.Debug;
import android.os.ParcelFileDescriptor;
import android.provider.MediaStore;
import android.view.accessibility.AccessibilityNodeInfo;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;

/** Black-box probe for the actual minified APK. Only Android framework APIs are
 * used so the runner cannot depend on classes removed or renamed inside the app. */
public final class ReleaseProbe extends Instrumentation {
    private Bundle arguments;
    private Uri fixture;
    private boolean keepFixture;
    @Override public void onCreate(Bundle args) { super.onCreate(args); arguments=args; start(); }
    private Bundle status() {
        Bundle b=new Bundle(); b.putString("class",getClass().getName());
        b.putString("test","signedReleaseGalleryViewerReelAndSettings");
        b.putString("id","FilmboxReleaseProbe"); b.putInt("numtests",1); b.putInt("current",1); return b;
    }
    @Override public void onStart() {
        Bundle started=status(); sendStatus(1,started);
        try {
            for(String permission:new String[]{"READ_MEDIA_IMAGES","READ_MEDIA_VIDEO"}) {
                try(ParcelFileDescriptor fd=getUiAutomation().executeShellCommand("pm grant com.filmbox.app android.permission."+permission)) {
                    new ParcelFileDescriptor.AutoCloseInputStream(fd).readAllBytes();
                }
            }
            if("verify".equals(arguments.getString("upgrade"))){verifyUpgrade();return;}
            Bitmap image=Bitmap.createBitmap(1200,800,Bitmap.Config.ARGB_8888);
            Canvas canvas=new Canvas(image); canvas.drawColor(0xff809da9);
            Paint p=new Paint(Paint.ANTI_ALIAS_FLAG);p.setColor(0xffebd4a0);canvas.drawCircle(870,220,90,p);
            p.setColor(0xff345258);canvas.drawRect(0,520,1200,800,p);
            ContentValues values=new ContentValues();values.put(MediaStore.MediaColumns.DISPLAY_NAME,"FILMBOX_SIGNED_RELEASE_QA.jpg");values.put(MediaStore.MediaColumns.MIME_TYPE,"image/jpeg");values.put(MediaStore.MediaColumns.RELATIVE_PATH,"Pictures/FilmboxQA");values.put(MediaStore.MediaColumns.IS_PENDING,1);
            fixture=getTargetContext().getContentResolver().insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI,values);
            try(java.io.OutputStream out=getTargetContext().getContentResolver().openOutputStream(fixture)){image.compress(Bitmap.CompressFormat.JPEG,95,out);}image.recycle();
            values.clear();values.put(MediaStore.MediaColumns.IS_PENDING,0);getTargetContext().getContentResolver().update(fixture,values,null,null);
            Intent launch=getTargetContext().getPackageManager().getLaunchIntentForPackage("com.filmbox.app");launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK);
            Activity app=startActivitySync(launch); if(app.isFinishing())throw new AssertionError("Activity did not start");
            waitNode("FILMBOX_SIGNED_RELEASE_QA.jpg"); waitPhotoPixels(); screenshot("gallery");
            if("prepare".equals(arguments.getString("upgrade"))){prepareUpgrade();return;}
            click("FILMBOX_SIGNED_RELEASE_QA.jpg");waitNode("关闭查看器");doubleTapPhoto();waitZoom("250%");screenshot("viewer");
            click("关闭查看器");click("切换浏览模式");waitNode("下一项");waitPhotoPixels();screenshot("reel");
            click("资源库");click("设置");waitNode("外观");click("外观");click("深色");waitSelected("深色");waitDarkSurface();screenshot("settings");
            Debug.MemoryInfo memory=new Debug.MemoryInfo();Debug.getMemoryInfo(memory);
            try(FileOutputStream out=new FileOutputStream(file("memory.txt"))){out.write(("totalPssKb="+memory.getTotalPss()+"\nnativePssKb="+memory.nativePss+"\ndalvikPssKb="+memory.dalvikPss+"\n").getBytes(StandardCharsets.UTF_8));}
            cleanupFixture();
            Bundle passed=status();passed.putString("stream","Signed APK launch, image zoom, reel and settings passed.\n");sendStatus(0,passed);
            Bundle done=new Bundle();done.putString("stream","OK (1 test)\n");finish(Activity.RESULT_OK,done);
        } catch(Throwable failure) {
            try{screenshot("failure");}catch(Exception ignored){}
            cleanupFixture();
            Bundle failed=status();failed.putString("stack",failure.toString());failed.putString("stream",failure.toString());sendStatus(-2,failed);
            Bundle done=new Bundle();done.putString("stream","FAILURES (1 test)\n");finish(Activity.RESULT_CANCELED,done);
        } finally {
            cleanupFixture();
        }
    }
    private void prepareUpgrade() throws Exception {
        String version=getTargetContext().getPackageManager().getPackageInfo("com.filmbox.app",0).versionName;
        if(!"0.4.0".equals(version))throw new AssertionError("Upgrade must start with Android 0.4.0");
        click("FILMBOX_SIGNED_RELEASE_QA.jpg");waitNode("关闭查看器");click("收藏");waitSelected("收藏");
        click("关闭查看器");
        if(!getTargetContext().getSharedPreferences("release-upgrade-qa",0).edit().putString("fixture",fixture.toString()).commit())throw new AssertionError("Could not store upgrade marker");
        keepFixture=true;
        passUpgrade("Prepared Android 0.4.0 with a real gallery favorite.");
    }
    private void verifyUpgrade() throws Exception {
        String version=getTargetContext().getPackageManager().getPackageInfo("com.filmbox.app",0).versionName;
        if(!"0.4.1".equals(version))throw new AssertionError("Updated Android version differs");
        String uri=getTargetContext().getSharedPreferences("release-upgrade-qa",0).getString("fixture",null);
        if(uri==null)throw new AssertionError("Previous installation data was lost");
        fixture=Uri.parse(uri);
        Intent launch=getTargetContext().getPackageManager().getLaunchIntentForPackage("com.filmbox.app");launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK|Intent.FLAG_ACTIVITY_CLEAR_TASK);
        startActivitySync(launch);
        waitNode("FILMBOX_SIGNED_RELEASE_QA.jpg");click("FILMBOX_SIGNED_RELEASE_QA.jpg");waitNode("关闭查看器");waitSelected("收藏");
        screenshot("upgrade-favorite");click("关闭查看器");
        cleanupFixture();getTargetContext().getSharedPreferences("release-upgrade-qa",0).edit().clear().commit();
        passUpgrade("Android 0.4.0 to 0.4.1 retained the gallery favorite and application data.");
    }
    private void passUpgrade(String message) {
        Bundle passed=status();passed.putString("stream",message+"\n");sendStatus(0,passed);
        Bundle done=new Bundle();done.putString("stream","OK (1 test)\n");finish(Activity.RESULT_OK,done);
    }
    private void doubleTapPhoto() throws Exception {
        AccessibilityNodeInfo photo=waitNode("媒体查看器");android.graphics.Rect bounds=new android.graphics.Rect();photo.getBoundsInScreen(bounds);
        for(int i=0;i<2;i++) {
            long down=android.os.SystemClock.uptimeMillis();
            android.view.MotionEvent press=android.view.MotionEvent.obtain(down,down,android.view.MotionEvent.ACTION_DOWN,bounds.centerX(),bounds.centerY(),0);
            press.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);getUiAutomation().injectInputEvent(press,true);press.recycle();
            android.os.SystemClock.sleep(20);
            android.view.MotionEvent release=android.view.MotionEvent.obtain(down,android.os.SystemClock.uptimeMillis(),android.view.MotionEvent.ACTION_UP,bounds.centerX(),bounds.centerY(),0);
            release.setSource(android.view.InputDevice.SOURCE_TOUCHSCREEN);getUiAutomation().injectInputEvent(release,true);release.recycle();
            if(i==0)android.os.SystemClock.sleep(80);
        }
    }
    private void waitZoom(String expected) throws Exception {
        long end=System.currentTimeMillis()+5000;
        while(System.currentTimeMillis()<end){AccessibilityNodeInfo photo=waitNode("媒体查看器");if(expected.contentEquals(photo.getStateDescription()==null?"":photo.getStateDescription()))return;Thread.sleep(100);}
        throw new AssertionError("Gesture zoom did not update");
    }
    private void cleanupFixture(){if(keepFixture)return;if(fixture!=null){try{getTargetContext().getContentResolver().delete(fixture,null,null);}catch(Exception ignored){}fixture=null;}}
    private AccessibilityNodeInfo find(AccessibilityNodeInfo root,String value) {
        if(root==null)return null;
        if(value.contentEquals(root.getText()==null?"":root.getText())||value.contentEquals(root.getContentDescription()==null?"":root.getContentDescription()))return root;
        for(int i=0;i<root.getChildCount();i++){AccessibilityNodeInfo match=find(root.getChild(i),value);if(match!=null)return match;}
        return null;
    }
    private AccessibilityNodeInfo waitNode(String value) throws Exception {
        long end=System.currentTimeMillis()+15000;
        while(System.currentTimeMillis()<end){AccessibilityNodeInfo match=find(getUiAutomation().getRootInActiveWindow(),value);if(match!=null)return match;Thread.sleep(100);}
        throw new AssertionError("Missing UI: "+value);
    }
    private AccessibilityNodeInfo findPhoto(AccessibilityNodeInfo root){
        if(root==null)return null;
        if("FILMBOX_SIGNED_RELEASE_QA.jpg".contentEquals(root.getContentDescription()==null?"":root.getContentDescription()))return root;
        for(int i=0;i<root.getChildCount();i++){AccessibilityNodeInfo found=findPhoto(root.getChild(i));if(found!=null)return found;}return null;
    }
    private void waitPhotoPixels() throws Exception {
        long end=System.currentTimeMillis()+15000;
        while(System.currentTimeMillis()<end){
            AccessibilityNodeInfo photo=findPhoto(getUiAutomation().getRootInActiveWindow());
            Bitmap screen=getUiAutomation().takeScreenshot();
            if(photo!=null&&screen!=null){android.graphics.Rect bounds=new android.graphics.Rect();photo.getBoundsInScreen(bounds);
                // Sample below the floating date, within the generated photo's blue sky.
                int x=Math.max(0,Math.min(screen.getWidth()-1,bounds.left+bounds.width()/6));int y=Math.max(0,Math.min(screen.getHeight()-1,bounds.top+bounds.height()*2/5));
                int color=screen.getPixel(x,y);screen.recycle();if(Math.abs(android.graphics.Color.red(color)-128)<25&&Math.abs(android.graphics.Color.green(color)-157)<25&&Math.abs(android.graphics.Color.blue(color)-169)<25)return;
            }else if(screen!=null)screen.recycle();Thread.sleep(100);
        }
        throw new AssertionError("Photo did not finish rendering");
    }
    private void waitDarkSurface() throws Exception {
        long end=System.currentTimeMillis()+15000;
        while(System.currentTimeMillis()<end){Bitmap screen=getUiAutomation().takeScreenshot();if(screen!=null){int color=screen.getPixel(screen.getWidth()/20,screen.getHeight()*4/5);screen.recycle();if(android.graphics.Color.red(color)<80&&android.graphics.Color.green(color)<80&&android.graphics.Color.blue(color)<80)return;}Thread.sleep(100);}
        throw new AssertionError("Dark theme did not finish rendering");
    }
    private void waitSelected(String value) throws Exception {
        long end=System.currentTimeMillis()+15000;
        while(System.currentTimeMillis()<end){AccessibilityNodeInfo n=find(getUiAutomation().getRootInActiveWindow(),value);while(n!=null){if(n.isSelected()||n.isChecked())return;n=n.getParent();}Thread.sleep(100);}
        throw new AssertionError("Selection did not update: "+value);
    }
    private void click(String value) throws Exception {
        AccessibilityNodeInfo n=waitNode(value);
        while(n!=null){if(n.isClickable()&&n.performAction(AccessibilityNodeInfo.ACTION_CLICK)){getUiAutomation().waitForIdle(500,3000);return;}n=n.getParent();}
        throw new AssertionError("Not clickable: "+value);
    }
    private File file(String name) {
        String path=arguments.getString("additionalTestOutputDir",getTargetContext().getExternalFilesDir(null).getAbsolutePath());
        File file=new File(path,"signed-release/"+name);file.getParentFile().mkdirs();return file;
    }
    private void screenshot(String name) throws Exception {
        getUiAutomation().waitForIdle(500,3000);waitForIdleSync();Thread.sleep(200);Bitmap bitmap=getUiAutomation().takeScreenshot();
        if(bitmap==null)throw new AssertionError("Screenshot unavailable");
        try(FileOutputStream out=new FileOutputStream(file(name+".png"))){bitmap.compress(Bitmap.CompressFormat.PNG,100,out);}bitmap.recycle();
    }
}
