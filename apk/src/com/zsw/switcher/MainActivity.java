package com.zsw.switcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Properties;

/**
 * 造梦西游OL 换号器（安卓版）
 *
 * 原理：每个号手动登录一次 -> 用 root 把游戏目录里的"登录态数据"打包成一个存档；
 *       换号时把存档写回游戏目录 + 重启游戏 -> 游戏读到旧登录态，免密进游戏。
 *
 * 需要：设备已 root（雷电9 默认可以开），游戏包名可改。
 */
public class MainActivity extends Activity {

    private static final String DEF_PKG = "org.yjmobile.zmxy";
    private static final List<String> SKIP = Arrays.asList("cache", "code_cache", "app_libs");

    private SharedPreferences sp;
    private final Handler ui = new Handler(Looper.getMainLooper());
    private volatile boolean busy = false;

    private LinearLayout listBox;
    private TextView logView;
    private EditText nameInput, pkgInput, waitInput;
    private CheckBox autoChk;
    private final StringBuilder logBuf = new StringBuilder();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        sp = getSharedPreferences("cfg", MODE_PRIVATE);
        try {
            View v = buildUi();
            setContentView(v);
            android.util.Log.e("ZSW", "ui ok, children=" + ((ViewGroup) v).getChildCount());
        } catch (Throwable t) {
            android.util.Log.e("ZSW", "buildUi failed", t);
            TextView tvErr = new TextView(this);
            tvErr.setText("界面构建失败：" + t);
            setContentView(tvErr);
        }
        refreshList();
        log("就绪：① 手动登录一个号 ② 填名字 ③ 抓取当前账号");
        log("游戏包名：" + pkg());
        new Thread(new Runnable() {
            public void run() {
                final String s = su("id");
                post(new Runnable() {
                    public void run() {
                        log("root: " + (s.contains("uid=0") ? "正常" : "拿不到 root！看下模拟器有没有给这个应用授权"));
                    }
                });
            }
        }).start();
    }

    // ---------------------------------------------------------------- 基础

    private File profDir() {
        File d = new File(getFilesDir(), "profiles");
        if (!d.exists()) d.mkdirs();
        return d;
    }

    private String pkg() {
        String p = pkgInput != null ? pkgInput.getText().toString().trim() : "";
        if (p.length() == 0) p = sp.getString("pkg", DEF_PKG);
        return p;
    }

    private int waitSec() {
        try {
            int v = Integer.parseInt(waitInput.getText().toString().trim());
            if (v < 4) v = 4;
            if (v > 300) v = 300;
            return v;
        } catch (Exception e) {
            return 20;
        }
    }

    /** 以 root 执行一条 shell 命令，返回合并后的输出 */
    private String su(String cmd) {
        StringBuilder sb = new StringBuilder();
        java.lang.Process p = null;
        try {
            p = new ProcessBuilder("su", "-c", cmd).redirectErrorStream(true).start();
            BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String line;
            while ((line = br.readLine()) != null) {
                sb.append(line).append('\n');
            }
            br.close();
            p.waitFor();
        } catch (Exception e) {
            sb.append("EX:").append(e.toString());
        } finally {
            if (p != null) try { p.destroy(); } catch (Exception ignored) { }
        }
        return sb.toString().trim();
    }

    private void post(Runnable r) {
        ui.post(r);
    }

    private void log(final String s) {
        post(new Runnable() {
            public void run() {
                logBuf.append(s).append('\n');
                if (logBuf.length() > 12000) logBuf.delete(0, logBuf.length() - 12000);
                if (logView != null) {
                    logView.setText(logBuf.toString());
                    try {
                        int h = logView.getLayout().getLineTop(logView.getLineCount());
                        int viewH = logView.getHeight();
                        if (h > viewH) {
                            View parent = (View) logView.getParent();
                            if (parent != null) parent.scrollTo(0, h - viewH);
                        }
                    } catch (Exception ignored) { }
                }
            }
        });
    }

    private void setBusy(final boolean on) {
        busy = on;
        post(new Runnable() {
            public void run() {
                if (listBox != null) setEnabledDeep(listBox, !on);
            }
        });
    }

    private void setEnabledDeep(View v, boolean en) {
        v.setEnabled(en);
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) setEnabledDeep(g.getChildAt(i), en);
        }
    }

    private TextView tv(String s, int sizeSp, boolean bold, int color) {
        TextView t = new TextView(this);
        t.setText(s);
        t.setTextSize(sizeSp);
        if (bold) t.setTypeface(Typeface.DEFAULT_BOLD);
        t.setTextColor(color);
        t.setPadding(2, 6, 2, 6);
        return t;
    }

    private Button btn(String s, boolean primary) {
        Button b = new Button(this);
        b.setText(s);
        b.setAllCaps(false);
        if (primary) b.setBackgroundColor(Color.parseColor("#2D6EEB"));
        return b;
    }

    // ---------------------------------------------------------------- 界面

    private View buildUi() {
        ScrollView root = new ScrollView(this);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setPadding(24, 24, 24, 24);
        root.addView(box, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        // --- 游戏包名 ---
        box.addView(tv("游戏包名", 13, true, Color.DKGRAY));
        LinearLayout pkgRow = new LinearLayout(this);
        pkgRow.setOrientation(LinearLayout.HORIZONTAL);
        pkgInput = new EditText(this);
        pkgInput.setInputType(InputType.TYPE_CLASS_TEXT);
        pkgInput.setText(sp.getString("pkg", DEF_PKG));
        pkgInput.setTextSize(13);
        pkgRow.addView(pkgInput, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button savePkg = btn("保存", false);
        savePkg.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                sp.edit().putString("pkg", pkg()).apply();
                log("包名已保存：" + pkg());
            }
        });
        pkgRow.addView(savePkg);
        box.addView(pkgRow);

        // --- 抓取 ---
        box.addView(tv("抓这个号（先手动登录好再点）", 13, true, Color.DKGRAY));
        LinearLayout nameRow = new LinearLayout(this);
        nameRow.setOrientation(LinearLayout.HORIZONTAL);
        nameInput = new EditText(this);
        nameInput.setHint("名字，例如 大号 / 小号1");
        nameInput.setTextSize(13);
        nameInput.setInputType(InputType.TYPE_CLASS_TEXT);
        nameRow.addView(nameInput, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button capBtn = btn("抓取当前账号", true);
        capBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) {
                final String n = nameInput.getText().toString().trim();
                if (n.length() == 0) { Toast.makeText(MainActivity.this, "先起个名字", Toast.LENGTH_SHORT).show(); return; }
                if (n.matches(".*[\\\\/:*?\"<>|].*")) { Toast.makeText(MainActivity.this, "名字不能带 / : * ? \" < > |", Toast.LENGTH_SHORT).show(); return; }
                if (new File(profDir(), n).exists()) {
                    new AlertDialog.Builder(MainActivity.this)
                            .setTitle("覆盖？")
                            .setMessage("已经有 [" + n + "] 的存档了，重新抓取会覆盖它。")
                            .setPositiveButton("覆盖", new DialogInterface.OnClickListener() {
                                public void onClick(DialogInterface d, int w) { doCapture(n, true); }
                            })
                            .setNegativeButton("取消", null).show();
                } else {
                    doCapture(n, true);
                }
            }
        });
        nameRow.addView(capBtn);
        box.addView(nameRow);

        // --- 选项 ---
        LinearLayout optRow = new LinearLayout(this);
        optRow.setOrientation(LinearLayout.HORIZONTAL);
        optRow.setGravity(Gravity.CENTER_VERTICAL);
        autoChk = new CheckBox(this);
        autoChk.setText("登录后回写登录态");
        autoChk.setTextSize(13);
        autoChk.setChecked(sp.getBoolean("auto", true));
        LinearLayout.LayoutParams lpChk = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT);
        lpChk.rightMargin = 30;
        optRow.addView(autoChk, lpChk);

        TextView tvW = tv("等", 13, false, Color.DKGRAY);
        tvW.setPadding(0, 8, 6, 0);
        optRow.addView(tvW);
        waitInput = new EditText(this);
        waitInput.setInputType(InputType.TYPE_CLASS_NUMBER);
        waitInput.setText(String.valueOf(sp.getInt("wait", 20)));
        waitInput.setTextSize(13);
        optRow.addView(waitInput, new LinearLayout.LayoutParams(110,
                ViewGroup.LayoutParams.WRAP_CONTENT));
        TextView tvS = tv("秒后自动更新存档", 11, false, Color.GRAY);
        tvS.setPadding(6, 8, 0, 0);
        optRow.addView(tvS);
        box.addView(optRow);

        // --- 列表 ---
        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        titleRow.addView(tv("账号（点按钮直接换号）", 13, true, Color.DKGRAY),
                new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        Button refreshBtn = btn("刷新", false);
        refreshBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { refreshList(); }
        });
        titleRow.addView(refreshBtn);
        box.addView(titleRow);

        listBox = new LinearLayout(this);
        listBox.setOrientation(LinearLayout.VERTICAL);
        box.addView(listBox);

        // --- 日志 ---
        Button diagBtn = btn("诊断（看 root / 数据目录）", false);
        diagBtn.setOnClickListener(new View.OnClickListener() {
            public void onClick(View v) { doDiag(); }
        });
        box.addView(diagBtn);

        logView = new TextView(this);
        logView.setTextSize(11);
        logView.setTypeface(Typeface.MONOSPACE);
        logView.setTextColor(Color.parseColor("#333333"));
        logView.setBackgroundColor(Color.parseColor("#F5F6F8"));
        logView.setPadding(12, 12, 12, 12);
        logView.setTextIsSelectable(true);
        logView.setMinLines(8);
        box.addView(logView, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, 680));

        return root;
    }

    // ---------------------------------------------------------------- 列表

    private void refreshList() {
        if (listBox == null) return;
        listBox.removeAllViews();
        File[] dirs = profDir().listFiles();
        List<File> list = new ArrayList<File>();
        if (dirs != null) {
            for (File f : dirs) if (f.isDirectory()) list.add(f);
        }
        if (list.isEmpty()) {
            listBox.addView(tv("还没有存档。手动登录一个号，填名字，点「抓取当前账号」。", 12, false, Color.GRAY));
            return;
        }
        for (final File d : list) {
            LinearLayout row = new LinearLayout(this);
            row.setOrientation(LinearLayout.HORIZONTAL);
            row.setGravity(Gravity.CENTER_VERTICAL);
            row.setPadding(0, 8, 0, 8);

            LinearLayout texts = new LinearLayout(this);
            texts.setOrientation(LinearLayout.VERTICAL);
            texts.addView(tv(d.getName(), 15, true, Color.BLACK));
            Properties p = readMeta(d);
            String info = p.getProperty("captured", "?") + " · " + p.getProperty("model", "?");
            texts.addView(tv(info, 10, false, Color.GRAY));
            row.addView(texts, new LinearLayout.LayoutParams(0,
                    ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

            Button go = btn("一键登录", true);
            go.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) { doLogin(d.getName()); }
            });
            row.addView(go);

            Button upd = btn("重抓", false);
            upd.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) { doCapture(d.getName(), true); }
            });
            row.addView(upd);

            Button del = btn("×", false);
            del.setOnClickListener(new View.OnClickListener() {
                public void onClick(View v) {
                    new AlertDialog.Builder(MainActivity.this)
                            .setTitle("删除存档")
                            .setMessage("删掉 [" + d.getName() + "] 的存档？")
                            .setPositiveButton("删", new DialogInterface.OnClickListener() {
                                public void onClick(DialogInterface dd, int w) {
                                    deleteDir(d);
                                    refreshList();
                                    log("已删除存档：" + d.getName());
                                }
                            })
                            .setNegativeButton("取消", null).show();
                }
            });
            row.addView(del);

            listBox.addView(row);
            View line = new View(this);
            line.setBackgroundColor(Color.parseColor("#E6E8EC"));
            listBox.addView(line, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 2));
        }
    }

    private void deleteDir(File d) {
        File[] fs = d.listFiles();
        if (fs != null) for (File f : fs) { if (f.isDirectory()) deleteDir(f); else f.delete(); }
        d.delete();
    }

    private Properties readMeta(File dir) {
        Properties p = new Properties();
        File f = new File(dir, "meta.txt");
        if (f.exists()) {
            try {
                FileInputStream in = new FileInputStream(f);
                p.load(in);
                in.close();
            } catch (Exception ignored) { }
        }
        return p;
    }

    private void writeMeta(File dir, Properties p) {
        try {
            File f = new File(dir, "meta.txt");
            FileOutputStream out = new FileOutputStream(f);
            p.store(new OutputStreamWriter(out, "UTF-8"), null);
            out.close();
        } catch (Exception e) {
            log("写 meta 失败：" + e);
        }
    }

    // ---------------------------------------------------------------- 核心

    private List<String> gameItems() {
        List<String> out = new ArrayList<String>();
        String s = su("ls -1 /data/data/" + pkg());
        for (String line : s.split("\n")) {
            String t = line.trim();
            if (t.length() == 0) continue;
            if (t.matches(".*[\\s;|&].*")) continue;
            if (SKIP.contains(t)) continue;
            out.add(t);
        }
        return out;
    }

    private void doCapture(final String name, final boolean forceStop) {
        if (busy) return;
        setBusy(true);
        log("=== 抓取 [" + name + "] ===");
        new Thread(new Runnable() {
            public void run() {
                try {
                    String p = pkg();
                    List<String> items = gameItems();
                    if (items.isEmpty()) {
                        log("失败：读不到 /data/data/" + p + " —— 包名不对或没有 root");
                        return;
                    }
                    log("要打包：" + join(items));

                    if (forceStop) {
                        log("关闭游戏…");
                        su("am force-stop " + p);
                        sleep(700);
                    }

                    File dir = new File(profDir(), name);
                    if (!dir.exists()) dir.mkdirs();
                    File tgz = new File(dir, "snap.tgz");
                    if (tgz.exists()) tgz.delete();

                    String cmd = "cd /data/data/" + p + " && tar czf " + tgz.getAbsolutePath()
                            + " " + join(items);
                    String out = su(cmd);
                    if (out.length() > 0) log("tar: " + out);

                    if (!tgz.exists() || tgz.length() < 1024) {
                        log("失败：打包没生成有效文件");
                        return;
                    }
                    int uid = Process.myUid();
                    su("chown " + uid + ":" + uid + " " + tgz.getAbsolutePath());
                    su("restorecon " + tgz.getAbsolutePath());

                    Properties meta = new Properties();
                    meta.setProperty("pkg", p);
                    meta.setProperty("items", join(items));
                    meta.setProperty("captured", now());
                    meta.setProperty("model", su("getprop ro.product.model").replace('\n', ' '));
                    meta.setProperty("size", String.valueOf(tgz.length()));
                    writeMeta(dir, meta);

                    log(String.format("完成：%s  大小 %.2f MB", name, tgz.length() / 1048576.0));
                    post(new Runnable() { public void run() { refreshList(); } });
                } catch (Exception e) {
                    log("出错：" + e);
                } finally {
                    setBusy(false);
                }
            }
        }).start();
    }

    private void doLogin(final String name) {
        if (busy) return;
        setBusy(true);
        log("=== 切换到 [" + name + "] ===");
        new Thread(new Runnable() {
            public void run() {
                try {
                    File dir = new File(profDir(), name);
                    File tgz = new File(dir, "snap.tgz");
                    if (!tgz.exists()) { log("存档不存在"); return; }
                    Properties meta = readMeta(dir);
                    String p = meta.getProperty("pkg", pkg());
                    List<String> items = new ArrayList<String>();
                    String its = meta.getProperty("items", "");
                    for (String t : its.split(",")) if (t.trim().length() > 0) items.add(t.trim());
                    if (items.isEmpty()) { log("存档里没记录要还原哪些目录"); return; }

                    log("关闭游戏…");
                    su("am force-stop " + p);
                    sleep(800);

                    log("清理旧登录态…");
                    su("cd /data/data/" + p + " && rm -rf " + join(items));

                    log("写回登录态…");
                    String ex = su("cd /data/data/" + p + " && tar xzf " + tgz.getAbsolutePath());
                    if (ex.length() > 0) log("tar: " + ex);
                    su("restorecon -R /data/data/" + p);

                    String uid = su("stat -c %u /data/data/" + p).trim();
                    if (uid.matches("\\d+")) {
                        su("cd /data/data/" + p + " && chown -R " + uid + ":" + uid + " " + join(items));
                        log("权限已归位：" + uid);
                    }

                    String act = su("cmd package resolve-activity --brief " + p).trim();
                    String last = "";
                    for (String l : act.split("\n")) if (l.contains("/")) last = l.trim();
                    if (last.length() > 0) {
                        su("am start -n " + last);
                        log("已启动：" + last);
                    } else {
                        su("monkey -p " + p + " -c android.intent.category.LAUNCHER 1");
                        log("已启动（launcher）");
                    }

                    if (autoChk != null && autoChk.isChecked()) {
                        int w = waitSec();
                        log("等 " + w + " 秒后回写最新登录态…");
                        sleep(w * 1000L);
                        log("回写中（会重启一次游戏）…");
                        su("am force-stop " + p);
                        sleep(700);
                        String out = su("cd /data/data/" + p + " && tar czf " + tgz.getAbsolutePath() + " " + join(items));
                        if (out.length() > 0) log("tar: " + out);
                        int myUid = Process.myUid();
                        su("chown " + myUid + ":" + myUid + " " + tgz.getAbsolutePath());
                        Properties meta2 = readMeta(dir);
                        meta2.setProperty("captured", now());
                        meta2.setProperty("size", String.valueOf(tgz.length()));
                        writeMeta(dir, meta2);
                        su("am start -n " + last);
                        log("回写完成，游戏已重新打开");
                        post(new Runnable() { public void run() { refreshList(); } });
                    }
                    log("好了。");
                } catch (Exception e) {
                    log("出错：" + e);
                } finally {
                    setBusy(false);
                }
            }
        }).start();
    }

    private void doDiag() {
        if (busy) return;
        setBusy(true);
        log("=== 诊断 ===");
        new Thread(new Runnable() {
            public void run() {
                try {
                    String p = pkg();
                    log("包名：" + p);
                    log("root：" + su("id"));
                    log("uid：" + su("stat -c %u /data/data/" + p).trim());
                    log("目录：\n" + su("ls -la /data/data/" + p));
                    log("shared_prefs：\n" + su("ls -la /data/data/" + p + "/shared_prefs"));
                    log("最近 20 分钟改动：\n" + su("find /data/data/" + p + " -mmin -20 -type f 2>/dev/null | head -30"));
                } catch (Exception e) {
                    log("出错：" + e);
                } finally {
                    setBusy(false);
                }
            }
        }).start();
    }

    // ---------------------------------------------------------------- 工具

    private static String join(List<String> l) {
        StringBuilder sb = new StringBuilder();
        for (String s : l) { if (sb.length() > 0) sb.append(' '); sb.append(s); }
        return sb.toString();
    }

    private static void sleep(long ms) {
        try { Thread.sleep(ms); } catch (Exception ignored) { }
    }

    private static String now() {
        return new java.text.SimpleDateFormat("yyyy-MM-dd HH:mm:ss", java.util.Locale.CHINA)
                .format(new java.util.Date());
    }

    @Override
    protected void onPause() {
        super.onPause();
        try {
            sp.edit().putString("pkg", pkg())
                    .putBoolean("auto", autoChk != null && autoChk.isChecked())
                    .putInt("wait", waitSec())
                    .apply();
        } catch (Exception ignored) { }
    }
}
