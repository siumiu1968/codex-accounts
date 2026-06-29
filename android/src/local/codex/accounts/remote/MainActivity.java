package local.codex.accounts.remote;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.database.Cursor;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.RadialGradient;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.net.Uri;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.OpenableColumns;
import android.text.InputType;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.GridLayout;
import android.widget.HorizontalScrollView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.Space;
import android.widget.TextView;
import android.widget.Toast;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URLEncoder;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public final class MainActivity extends Activity {
    private static final int REQUEST_ATTACHMENTS = 4201;
    private static final int MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024;

    private final ExecutorService network = Executors.newFixedThreadPool(4);
    private final Handler main = new Handler(Looper.getMainLooper());
    private final List<Profile> profiles = new ArrayList<>();
    private final List<Conversation> conversations = new ArrayList<>();
    private final List<Attachment> pendingAttachments = new ArrayList<>();

    private SharedPreferences prefs;
    private EditText urlInput;
    private EditText accessClientIdInput;
    private EditText accessClientSecretInput;
    private EditText usernameInput;
    private EditText passwordInput;
    private EditText commandInput;
    private LinearLayout content;
    private LinearLayout authCardHost;
    private LinearLayout controlHost;
    private LinearLayout profileList;
    private LinearLayout conversationList;
    private TextView statusText;
    private TextView selectedText;
    private TextView targetText;
    private TextView attachmentText;
    private TextView heroMetric;
    private TextView heroSubtitle;
    private Button targetMacButton;
    private Button targetVpsButton;
    private ProgressBar connectionProgress;
    private String selectedTarget = "mac";
    private String selectedProfileId = "";
    private String selectedProfileName = "";
    private String selectedSessionId = "";
    private String selectedConversationTitle = "";
    private String sessionToken = "";
    private String signedInUser = "";
    private boolean showAccessFields = false;
    private boolean pollActive = false;
    private int conversationRequestId = 0;

    private final Runnable pollRunnable = new Runnable() {
        @Override
        public void run() {
            if (!pollActive) return;
            refreshProfiles(false);
            main.postDelayed(this, 7000);
        }
    };

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        prefs = getSharedPreferences("codex_remote", MODE_PRIVATE);
        selectedTarget = prefs.getString("selectedTarget", "mac");
        selectedProfileId = prefs.getString("selectedProfileId", "");
        selectedProfileName = prefs.getString("selectedProfileName", "");
        selectedSessionId = prefs.getString("selectedSessionId", "");
        selectedConversationTitle = prefs.getString("selectedConversationTitle", "");
        sessionToken = prefs.getString("sessionToken", "");
        signedInUser = prefs.getString("signedInUser", "");
        showAccessFields = prefs.getBoolean("showAccessFields", false)
            || !prefs.getString("cfAccessClientId", "").trim().isEmpty()
            || !prefs.getString("cfAccessClientSecret", "").trim().isEmpty();

        Window window = getWindow();
        window.setStatusBarColor(Color.TRANSPARENT);
        window.setNavigationBarColor(Color.rgb(5, 10, 14));

        setContentView(buildContent());
        updateSelectedText();
    }

    @Override
    protected void onDestroy() {
        pollActive = false;
        network.shutdownNow();
        super.onDestroy();
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQUEST_ATTACHMENTS || resultCode != RESULT_OK || data == null) return;
        loadAttachments(data);
    }

    private View buildContent() {
        FrameLayout root = new FrameLayout(this);
        root.addView(new AuroraBackgroundView(this), new FrameLayout.LayoutParams(-1, -1));

        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(false);
        scroll.setClipToPadding(false);

        content = new LinearLayout(this);
        content.setOrientation(LinearLayout.VERTICAL);
        content.setPadding(dp(18), dp(22), dp(18), dp(28));
        scroll.addView(content, new ScrollView.LayoutParams(-1, -2));

        content.addView(header());
        content.addView(space(16));
        authCardHost = vertical();
        controlHost = vertical();
        content.addView(authCardHost);
        content.addView(controlHost);
        renderAuthState();

        root.addView(scroll, new FrameLayout.LayoutParams(-1, -1));
        return root;
    }

    private void renderAuthState() {
        authCardHost.removeAllViews();
        controlHost.removeAllViews();
        authCardHost.addView(connectionCard());
        if (sessionToken.isEmpty()) {
            showSignedOut();
        } else {
            showSignedIn();
        }
    }

    private void showSignedOut() {
        pollActive = false;
        main.removeCallbacks(pollRunnable);
        controlHost.addView(space(14));
        controlHost.addView(loginCard());
        heroMetric.setText("Key");
        heroMetric.setTextColor(Color.rgb(255, 184, 61));
        heroSubtitle.setText("Pair once. Control Codex anywhere.");
    }

    private void showSignedIn() {
        controlHost.addView(space(14));
        controlHost.addView(sessionCard());
        controlHost.addView(space(14));
        controlHost.addView(targetCard());
        controlHost.addView(space(14));
        controlHost.addView(commandCard());
        controlHost.addView(space(14));
        controlHost.addView(conversationsCard());
        controlHost.addView(space(14));
        controlHost.addView(actionsCard());
        controlHost.addView(space(14));
        controlHost.addView(profilesCard());
        heroMetric.setText("Ready");
        heroMetric.setTextColor(Color.rgb(40, 242, 210));
        heroSubtitle.setText(signedInUser);
        updateSelectedText();
        connect();
    }

    private View header() {
        GlassPanel panel = new GlassPanel(this, 24, Color.argb(44, 30, 242, 211), Color.argb(36, 255, 118, 64));
        panel.setPadding(dp(18), dp(18), dp(18), dp(18));

        LinearLayout column = new LinearLayout(this);
        column.setOrientation(LinearLayout.VERTICAL);
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));

        TextView eyebrow = label("Bridge", 12, Color.rgb(122, 238, 226), true);
        eyebrow.setLetterSpacing(0.08f);
        column.addView(eyebrow);

        TextView title = label("Codex", 36, Color.WHITE, true);
        title.setPadding(0, dp(4), 0, 0);
        column.addView(title);

        heroSubtitle = label("Remote control for Mac + VPS.", 14, Color.argb(218, 232, 244, 246), false);
        heroSubtitle.setPadding(0, dp(8), 0, 0);
        column.addView(heroSubtitle);

        LinearLayout chips = new LinearLayout(this);
        chips.setOrientation(LinearLayout.HORIZONTAL);
        chips.setGravity(Gravity.CENTER_VERTICAL);
        chips.setPadding(0, dp(14), 0, 0);
        column.addView(chips);

        heroMetric = chip("Offline", Color.rgb(255, 69, 92), Color.argb(48, 255, 69, 92));
        chips.addView(heroMetric);
        chips.addView(spaceH(8));
        TextView tokenChip = chip("Password", Color.rgb(255, 184, 61), Color.argb(42, 255, 184, 61));
        chips.addView(tokenChip);

        return panel;
    }

    private View connectionCard() {
        GlassPanel panel = new GlassPanel(this, 22, Color.argb(38, 54, 169, 255), Color.argb(34, 40, 242, 210));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));
        column.addView(sectionTitle("Link"));

        urlInput = input("http://192.168.1.10:47621");
        urlInput.setText(prefs.getString("baseUrl", ""));
        column.addView(urlInput, matchWrap());
        column.addView(space(10));

        accessClientIdInput = null;
        accessClientSecretInput = null;
        if (showAccessFields) {
            accessClientIdInput = input("Access Client ID");
            accessClientIdInput.setText(prefs.getString("cfAccessClientId", ""));
            column.addView(accessClientIdInput, matchWrap());
            column.addView(space(10));

            accessClientSecretInput = input("Access Client Secret");
            accessClientSecretInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
            accessClientSecretInput.setText(prefs.getString("cfAccessClientSecret", ""));
            column.addView(accessClientSecretInput, matchWrap());
            column.addView(space(10));
        }

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        column.addView(row);

        Button save = actionButton("Save", Color.rgb(72, 192, 255));
        save.setOnClickListener(v -> {
            saveConnection();
            toast("Saved");
        });
        row.addView(save, weightedButton());
        row.addView(spaceH(10));

        Button connect = actionButton("Connect", Color.rgb(40, 242, 210));
        connect.setOnClickListener(v -> {
            saveConnection();
            connect();
        });
        row.addView(connect, weightedButton());
        row.addView(spaceH(10));

        Button access = smallButton("Key", Color.rgb(255, 184, 61));
        access.setContentDescription("Cloudflare Access");
        access.setOnClickListener(v -> {
            showAccessFields = !showAccessFields;
            prefs.edit().putBoolean("showAccessFields", showAccessFields).apply();
            renderAuthState();
        });
        row.addView(access, new LinearLayout.LayoutParams(dp(58), dp(46)));

        connectionProgress = new ProgressBar(this);
        connectionProgress.setVisibility(View.GONE);
        row.addView(spaceH(10));
        row.addView(connectionProgress, new LinearLayout.LayoutParams(dp(28), dp(28)));

        statusText = label("Bridge URL. Access token optional.", 13, Color.argb(190, 233, 243, 247), false);
        statusText.setPadding(0, dp(12), 0, 0);
        column.addView(statusText);
        return panel;
    }

    private View loginCard() {
        GlassPanel panel = new GlassPanel(this, 24, Color.argb(42, 40, 242, 210), Color.argb(28, 255, 255, 255));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));
        column.addView(sectionTitle("Login"));

        TextView copy = label("Use the mobile login from Codex Accounts.", 14, Color.argb(205, 236, 244, 246), false);
        copy.setPadding(0, 0, 0, dp(12));
        column.addView(copy);

        usernameInput = input("Username");
        usernameInput.setText(prefs.getString("username", ""));
        column.addView(usernameInput, matchWrap());
        column.addView(space(10));

        passwordInput = input("Password");
        passwordInput.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD);
        column.addView(passwordInput, matchWrap());
        column.addView(space(12));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        column.addView(row);

        Button login = actionButton("Log In", Color.rgb(40, 242, 210));
        login.setOnClickListener(v -> authenticate());
        row.addView(login, weightedButton());
        return panel;
    }

    private View sessionCard() {
        GlassPanel panel = new GlassPanel(this, 18, Color.argb(48, 40, 242, 210), Color.argb(24, 40, 242, 210));
        panel.setPadding(dp(14), dp(12), dp(14), dp(12));
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        panel.addView(row, new FrameLayout.LayoutParams(-1, -2));

        TextView user = label("User · " + signedInUser, 14, Color.WHITE, true);
        row.addView(user, new LinearLayout.LayoutParams(0, -2, 1));

        Button logout = smallButton("Exit", Color.rgb(255, 69, 92));
        logout.setOnClickListener(v -> logout());
        row.addView(logout);
        return panel;
    }

    private View targetCard() {
        GlassPanel panel = new GlassPanel(this, 20, Color.argb(76, 72, 192, 255), Color.argb(26, 72, 192, 255));
        panel.setPadding(dp(14), dp(14), dp(14), dp(14));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        column.addView(titleRow);
        titleRow.addView(sectionTitle("Target"), new LinearLayout.LayoutParams(0, -2, 1));
        targetText = chip(targetName(), Color.rgb(72, 192, 255), Color.argb(36, 72, 192, 255));
        titleRow.addView(targetText);

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        column.addView(row);

        targetMacButton = actionButton("⌘ Mac", targetAccent("mac"));
        targetMacButton.setOnClickListener(v -> setTarget("mac"));
        row.addView(targetMacButton, weightedButton());
        row.addView(spaceH(10));

        targetVpsButton = actionButton("☁ VPS", targetAccent("vps"));
        targetVpsButton.setOnClickListener(v -> setTarget("vps"));
        row.addView(targetVpsButton, weightedButton());
        return panel;
    }

    private View commandCard() {
        GlassPanel panel = new GlassPanel(this, 22, Color.argb(46, 40, 242, 210), Color.argb(30, 139, 92, 255));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));
        column.addView(sectionTitle("Prompt"));

        selectedText = chip("Pick account + thread", Color.rgb(228, 238, 240), Color.argb(34, 255, 255, 255));
        column.addView(selectedText, wrapWrap());
        column.addView(space(10));

        commandInput = input("Message Codex...");
        commandInput.setSingleLine(false);
        commandInput.setMinLines(4);
        commandInput.setGravity(Gravity.TOP | Gravity.START);
        column.addView(commandInput, matchWrap());
        column.addView(space(12));

        LinearLayout attachmentRow = new LinearLayout(this);
        attachmentRow.setOrientation(LinearLayout.HORIZONTAL);
        attachmentRow.setGravity(Gravity.CENTER_VERTICAL);
        column.addView(attachmentRow);

        Button attach = smallButton("+ File", Color.rgb(139, 92, 255));
        attach.setOnClickListener(v -> chooseAttachments());
        attachmentRow.addView(attach);
        attachmentRow.addView(spaceH(10));

        attachmentText = chip("0 files", Color.rgb(228, 238, 240), Color.argb(34, 255, 255, 255));
        attachmentRow.addView(attachmentText, new LinearLayout.LayoutParams(0, -2, 1));
        attachmentRow.addView(spaceH(10));

        Button clearAttachments = smallButton("×", Color.rgb(255, 69, 92));
        clearAttachments.setContentDescription("Clear attachments");
        clearAttachments.setOnClickListener(v -> {
            pendingAttachments.clear();
            updateAttachmentText();
        });
        attachmentRow.addView(clearAttachments);
        column.addView(space(12));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        column.addView(row);

        Button paste = actionButton("↩ Paste", Color.rgb(72, 192, 255));
        paste.setOnClickListener(v -> sendCommand(false));
        row.addView(paste, weightedButton());
        row.addView(spaceH(10));

        Button ask = actionButton("▶ Run", Color.rgb(40, 242, 210));
        ask.setOnClickListener(v -> askConversation());
        row.addView(ask, weightedButton());
        row.addView(spaceH(10));

        Button send = actionButton("⌘ Desk", Color.rgb(255, 184, 61));
        send.setOnClickListener(v -> sendCommand(true));
        row.addView(send, weightedButton());
        return panel;
    }

    private View conversationsCard() {
        GlassPanel panel = new GlassPanel(this, 22, Color.argb(44, 139, 92, 255), Color.argb(28, 40, 242, 210));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        column.addView(titleRow);
        titleRow.addView(sectionTitle("Threads"), new LinearLayout.LayoutParams(0, -2, 1));
        Button refresh = smallButton("↻", Color.rgb(72, 192, 255));
        refresh.setContentDescription("Load conversations");
        refresh.setOnClickListener(v -> refreshConversations(true));
        titleRow.addView(refresh);

        conversationList = new LinearLayout(this);
        conversationList.setOrientation(LinearLayout.VERTICAL);
        conversationList.setPadding(0, dp(12), 0, 0);
        column.addView(conversationList);
        showEmptyConversations("Tap ↻ to load.");
        return panel;
    }

    private View actionsCard() {
        GlassPanel panel = new GlassPanel(this, 22, Color.argb(32, 255, 178, 38), Color.argb(28, 255, 70, 88));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));
        column.addView(sectionTitle("Actions"));

        GridLayout grid = new GridLayout(this);
        grid.setColumnCount(2);
        grid.setUseDefaultMargins(false);
        column.addView(grid);

        grid.addView(tileButton("↻ Profiles", Color.rgb(72, 192, 255), v -> refreshProfiles(true)), gridCell());
        grid.addView(tileButton("⇄ Sync", Color.rgb(40, 242, 210), v -> postSimple("/sync", "Syncing", true)), gridCell());
        grid.addView(tileButton("☁ Sync", Color.rgb(255, 184, 61), v -> syncVps()), gridCell());
        grid.addView(tileButton("☁ Status", Color.rgb(139, 92, 255), v -> postSimple("/vps/status", "Checking VPS", false)), gridCell());
        grid.addView(tileButton("Share", Color.rgb(255, 184, 61), v -> postSimple("/share-all", "Sharing history", true)), gridCell());
        grid.addView(tileButton("✕ Close", Color.rgb(255, 69, 92), v -> postSimple("/close-all", "Closing all", true)), gridCell());
        return panel;
    }

    private View profilesCard() {
        GlassPanel panel = new GlassPanel(this, 22, Color.argb(40, 54, 169, 255), Color.argb(36, 40, 242, 210));
        panel.setPadding(dp(16), dp(16), dp(16), dp(16));

        LinearLayout column = vertical();
        panel.addView(column, new FrameLayout.LayoutParams(-1, -2));

        LinearLayout titleRow = new LinearLayout(this);
        titleRow.setOrientation(LinearLayout.HORIZONTAL);
        titleRow.setGravity(Gravity.CENTER_VERTICAL);
        column.addView(titleRow);
        titleRow.addView(sectionTitle("Accounts"), new LinearLayout.LayoutParams(0, -2, 1));
        TextView hint = label("live", 12, Color.argb(160, 188, 209, 216), true);
        titleRow.addView(hint);

        profileList = new LinearLayout(this);
        profileList.setOrientation(LinearLayout.VERTICAL);
        profileList.setPadding(0, dp(12), 0, 0);
        column.addView(profileList);
        showEmptyProfiles("Connect to your Mac bridge to load profiles.");
        return panel;
    }

    private void authenticate() {
        saveConnection();
        String username = usernameInput.getText().toString().trim();
        String password = passwordInput.getText().toString();
        if (username.isEmpty() || password.isEmpty()) {
            toast("Enter username and password");
            return;
        }
        JSONObject payload = new JSONObject();
        try {
            payload.put("username", username);
            payload.put("password", password);
        } catch (Exception ignored) {
        }
        setLoading(true, "Logging in...");
        postJson("/auth/login", payload, new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                sessionToken = json.optString("sessionToken", "");
                signedInUser = json.optString("username", username);
                prefs.edit()
                    .putString("username", signedInUser)
                    .putString("sessionToken", sessionToken)
                    .putString("signedInUser", signedInUser)
                    .apply();
                passwordInput.setText("");
                renderAuthState();
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
    }

    private void connect() {
        setLoading(true, "Connecting...");
        getJson("/health", new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                String host = json.optString("hostname", "Mac");
                heroMetric.setText("Online");
                heroMetric.setTextColor(Color.rgb(40, 242, 210));
                heroSubtitle.setText(host);
                pollActive = true;
                main.removeCallbacks(pollRunnable);
                main.post(pollRunnable);
                setLoading(false, "Online. Loading...");
                refreshConversations(false);
            }

            @Override
            public void onError(String message) {
                setLoading(false, connectionHelp(message));
                heroMetric.setText("Offline");
                heroMetric.setTextColor(Color.rgb(255, 69, 92));
            }
        });
    }

    private void refreshProfiles(boolean loud) {
        if (loud) setLoading(true, "Refreshing profiles...");
        getJson("/profiles", new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                profiles.clear();
                JSONArray array = json.optJSONArray("profiles");
                if (array != null) {
                    for (int i = 0; i < array.length(); i++) {
                        JSONObject item = array.optJSONObject(i);
                        if (item == null) continue;
                        Profile p = new Profile();
                        p.id = item.optString("id");
                        p.displayName = item.optString("displayName", p.id);
                        p.home = item.optString("home");
                        p.authStatus = item.optString("authStatus");
                        p.quota = item.optString("quota");
                        p.reset = item.optString("reset");
                        profiles.add(p);
                    }
                }
                renderProfiles();
                if (loud) {
                    setLoading(false, profiles.size() + " accounts");
                } else if (!isLoading()) {
                    statusText.setText(profiles.size() + " accounts");
                }
            }

            @Override
            public void onError(String message) {
                if (loud) {
                    setLoading(false, message);
                } else if (!isLoading()) {
                    statusText.setText(message);
                }
                if (loud) showEmptyProfiles(message);
            }
        });
    }

    private void renderProfiles() {
        profileList.removeAllViews();
        if (profiles.isEmpty()) {
            showEmptyProfiles("No accounts.");
            return;
        }
        for (Profile profile : profiles) {
            profileList.addView(profileRow(profile));
            profileList.addView(space(10));
        }
    }

    private void setTarget(String target) {
        String nextTarget = "vps".equals(target) ? "vps" : "mac";
        boolean changed = !selectedTarget.equals(nextTarget);
        if (!changed && conversationList != null && !conversations.isEmpty()) {
            return;
        }
        selectedTarget = nextTarget;
        selectedSessionId = "";
        selectedConversationTitle = "";
        conversations.clear();
        prefs.edit()
            .putString("selectedTarget", selectedTarget)
            .remove("selectedSessionId")
            .remove("selectedConversationTitle")
            .apply();
        if (targetText != null) targetText.setText(targetName());
        updateTargetButtons();
        updateSelectedText();
        if (conversationList != null) {
            showEmptyConversations("Loading...");
            refreshConversations(true);
        }
    }

    private String targetName() {
        return selectedTarget.equals("vps") ? "Japan VPS" : "MacBook";
    }

    private int targetAccent(String target) {
        if (selectedTarget.equals(target)) {
            return Color.rgb(40, 242, 210);
        }
        return "vps".equals(target) ? Color.rgb(255, 184, 61) : Color.rgb(72, 192, 255);
    }

    private void updateTargetButtons() {
        if (targetMacButton != null) styleActionButton(targetMacButton, targetAccent("mac"), 18);
        if (targetVpsButton != null) styleActionButton(targetVpsButton, targetAccent("vps"), 18);
    }

    private void refreshConversations(boolean loud) {
        if (loud) setLoading(true, "Loading conversations...");
        final int requestId = ++conversationRequestId;
        String query = "/codex/conversations?target=" + enc(selectedTarget) + "&limit=30";
        if (!selectedProfileId.isEmpty()) {
            query += "&profileId=" + enc(selectedProfileId);
        }
        getJson(query, new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                if (requestId != conversationRequestId) return;
                conversations.clear();
                JSONArray array = json.optJSONArray("conversations");
                if (array != null) {
                    for (int i = 0; i < array.length(); i++) {
                        JSONObject item = array.optJSONObject(i);
                        if (item == null) continue;
                        Conversation c = new Conversation();
                        c.id = item.optString("id");
                        c.title = item.optString("title", c.id);
                        c.updatedAt = item.optString("updatedAt");
                        c.projectLabel = item.optString("projectLabel");
                        c.source = item.optString("source");
                        conversations.add(c);
                    }
                }
                renderConversations();
                if (loud) {
                    setLoading(false, conversations.size() + " threads");
                } else if (!isLoading()) {
                    statusText.setText(conversations.size() + " threads · " + targetName());
                }
            }

            @Override
            public void onError(String message) {
                if (requestId != conversationRequestId) return;
                if (loud) {
                    setLoading(false, message);
                } else if (!isLoading()) {
                    statusText.setText(message);
                }
                if (loud) showEmptyConversations(message);
            }
        });
    }

    private void renderConversations() {
        if (conversationList == null) return;
        conversationList.removeAllViews();
        if (conversations.isEmpty()) {
            showEmptyConversations("No threads.");
            return;
        }
        for (Conversation conversation : conversations) {
            conversationList.addView(conversationRow(conversation));
            conversationList.addView(space(8));
        }
    }

    private View conversationRow(Conversation conversation) {
        boolean selected = conversation.id.equals(selectedSessionId);
        GlassPanel panel = new GlassPanel(this, 16, selected ? Color.argb(150, 40, 242, 210) : Color.argb(64, 255, 255, 255), selected ? Color.argb(44, 40, 242, 210) : Color.argb(24, 255, 255, 255));
        panel.setPadding(dp(12), dp(10), dp(12), dp(10));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        panel.addView(row, new FrameLayout.LayoutParams(-1, -2));

        LinearLayout info = vertical();
        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1));
        TextView title = label(conversation.title, 15, Color.WHITE, true);
        title.setSingleLine(true);
        info.addView(title);
        String meta = conversation.projectLabel.isEmpty() ? conversation.updatedAt : conversation.projectLabel + " · " + conversation.updatedAt;
        TextView details = label(meta, 11, Color.argb(160, 224, 234, 238), false);
        details.setSingleLine(true);
        info.addView(details);

        Button choose = smallButton(selected ? "✓" : "Use", selected ? Color.rgb(255, 184, 61) : Color.rgb(40, 242, 210));
        choose.setContentDescription(selected ? "Selected conversation" : "Use conversation");
        choose.setOnClickListener(v -> {
            selectedSessionId = conversation.id;
            selectedConversationTitle = conversation.title;
            prefs.edit()
                .putString("selectedSessionId", selectedSessionId)
                .putString("selectedConversationTitle", selectedConversationTitle)
                .apply();
            updateSelectedText();
            renderConversations();
        });
        row.addView(spaceH(10));
        row.addView(choose);
        return panel;
    }

    private View profileRow(Profile profile) {
        GlassPanel panel = new GlassPanel(this, 18, profileAccent(profile).stroke, profileAccent(profile).fill);
        panel.setPadding(dp(12), dp(12), dp(12), dp(12));

        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        panel.addView(row, new FrameLayout.LayoutParams(-1, -2));

        AvatarView avatar = new AvatarView(this, profile.displayName);
        row.addView(avatar, new LinearLayout.LayoutParams(dp(54), dp(54)));
        row.addView(spaceH(12));

        LinearLayout info = vertical();
        row.addView(info, new LinearLayout.LayoutParams(0, -2, 1));
        TextView name = label(profile.displayName, 18, Color.WHITE, true);
        info.addView(name);
        TextView home = label(shortHome(profile.home), 12, Color.argb(166, 224, 234, 238), false);
        home.setSingleLine(true);
        info.addView(home);
        info.addView(space(8));
        info.addView(quotaStrip(profile));

        row.addView(spaceH(10));
        LinearLayout buttons = new LinearLayout(this);
        buttons.setOrientation(LinearLayout.VERTICAL);
        buttons.setGravity(Gravity.CENTER);
        row.addView(buttons);

        Button open = smallButton("↗", Color.rgb(40, 242, 210));
        open.setContentDescription("Open profile");
        open.setOnClickListener(v -> postProfile(profile, "open", "/profiles/" + enc(profile.id) + "/open"));
        buttons.addView(open);
        buttons.addView(space(8));

        Button select = smallButton(isSelected(profile) ? "✓" : "Use", isSelected(profile) ? Color.rgb(255, 184, 61) : Color.rgb(72, 192, 255));
        select.setContentDescription(isSelected(profile) ? "Selected profile" : "Use profile");
        select.setOnClickListener(v -> {
            selectedProfileId = profile.id;
            selectedProfileName = profile.displayName;
            prefs.edit().putString("selectedProfileId", selectedProfileId).putString("selectedProfileName", selectedProfileName).apply();
            updateSelectedText();
            renderProfiles();
        });
        buttons.addView(select);

        Button close = iconButton("×", Color.rgb(255, 69, 92));
        close.setOnClickListener(v -> postProfile(profile, "close", "/profiles/" + enc(profile.id) + "/close"));
        LinearLayout.LayoutParams closeLp = new LinearLayout.LayoutParams(dp(42), dp(42));
        closeLp.setMargins(dp(8), 0, 0, 0);
        row.addView(close, closeLp);

        return panel;
    }

    private View quotaStrip(Profile profile) {
        LinearLayout column = vertical();
        List<QuotaPart> parts = QuotaPart.parse(profile.quota, profile.reset);
        if (parts.isEmpty()) {
            TextView unknown = label(profile.authStatus.equals("login_needed") ? "Login" : "No quota", 12, Color.argb(180, 228, 235, 238), true);
            column.addView(unknown);
            return column;
        }
        for (QuotaPart part : parts) {
            LinearLayout line = new LinearLayout(this);
            line.setOrientation(LinearLayout.HORIZONTAL);
            line.setGravity(Gravity.CENTER_VERTICAL);
            column.addView(line);

            TextView label = label(part.label, 12, part.label.equalsIgnoreCase("5h") ? Color.rgb(72, 192, 255) : Color.rgb(255, 184, 61), true);
            line.addView(label, new LinearLayout.LayoutParams(dp(28), -2));
            line.addView(bar(part.percent, part.goodColor()), new LinearLayout.LayoutParams(0, dp(10), 1));
            TextView meta = label(part.meta, 12, Color.argb(205, 239, 246, 248), true);
            meta.setGravity(Gravity.END);
            line.addView(meta, new LinearLayout.LayoutParams(dp(76), -2));
        }
        return column;
    }

    private View bar(int percent, int color) {
        FrameLayout frame = new FrameLayout(this);
        frame.setPadding(0, 0, 0, 0);
        GradientDrawable track = roundDrawable(Color.argb(48, 255, 255, 255), 999, Color.argb(35, 255, 255, 255), 1);
        frame.setBackground(track);

        View fill = new View(this);
        GradientDrawable fillBg = new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, new int[]{color, Color.rgb(40, 242, 210)});
        fillBg.setCornerRadius(dp(999));
        fill.setBackground(fillBg);
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(1, -1);
        lp.gravity = Gravity.START;
        frame.addView(fill, lp);
        frame.post(() -> {
            int width = Math.max(1, Math.round(frame.getWidth() * Math.max(0, Math.min(100, percent)) / 100f));
            ViewGroup.LayoutParams params = fill.getLayoutParams();
            params.width = width;
            fill.setLayoutParams(params);
        });
        return frame;
    }

    private void sendCommand(boolean submit) {
        String text = commandInput.getText().toString();
        if (text.trim().isEmpty()) {
            toast("Type a prompt first");
            return;
        }
        if (selectedProfileId.isEmpty()) {
            toast("Select a profile first");
            return;
        }
        JSONObject payload = new JSONObject();
        try {
            payload.put("profileId", selectedProfileId);
            payload.put("text", text);
            payload.put("submit", submit);
        } catch (Exception ignored) {
        }
        postJson("/send", payload, new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                setLoading(false, submit ? "Prompt sent" : "Prompt pasted");
                if (submit) commandInput.setText("");
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
        setLoading(true, submit ? "Opening profile and sending..." : "Opening profile and pasting...");
    }

    private void askConversation() {
        String text = commandInput.getText().toString();
        if (text.trim().isEmpty() && pendingAttachments.isEmpty()) {
            toast("Type a prompt or attach a file first");
            return;
        }
        if (selectedSessionId.isEmpty()) {
            toast("Select a conversation first");
            return;
        }
        JSONObject payload = new JSONObject();
        try {
            payload.put("target", selectedTarget);
            payload.put("profileId", selectedProfileId);
            payload.put("sessionId", selectedSessionId);
            payload.put("text", text);
            payload.put("timeout", 1800);
            JSONArray attachments = new JSONArray();
            for (Attachment attachment : pendingAttachments) {
                JSONObject item = new JSONObject();
                item.put("name", attachment.name);
                item.put("mimeType", attachment.mimeType);
                item.put("dataBase64", attachment.dataBase64);
                attachments.put(item);
            }
            payload.put("attachments", attachments);
        } catch (Exception ignored) {
        }
        setLoading(true, "Continuing on " + targetName() + "...");
        postJson("/codex/ask", payload, new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                commandInput.setText("");
                pendingAttachments.clear();
                updateAttachmentText();
                setLoading(false, json.optString("output", "Codex finished"));
                refreshConversations(false);
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
    }

    private void syncVps() {
        JSONObject payload = new JSONObject();
        try {
            payload.put("direction", "two-way");
        } catch (Exception ignored) {
        }
        setLoading(true, "Syncing VPS...");
        postJson("/vps/sync", payload, new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                setLoading(false, json.optString("message", "VPS synced"));
                if (selectedTarget.equals("vps")) refreshConversations(false);
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
    }

    private void chooseAttachments() {
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        intent.setType("*/*");
        intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/*", "application/pdf", "text/*"});
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true);
        startActivityForResult(Intent.createChooser(intent, "Choose files for Codex"), REQUEST_ATTACHMENTS);
    }

    private void loadAttachments(Intent data) {
        setLoading(true, "Reading attachment...");
        network.execute(() -> {
            List<Attachment> loaded = new ArrayList<>();
            try {
                ClipData clipData = data.getClipData();
                if (clipData != null) {
                    int count = Math.min(clipData.getItemCount(), 8);
                    for (int i = 0; i < count; i++) {
                        Attachment attachment = readAttachment(clipData.getItemAt(i).getUri(), i + 1);
                        if (attachment != null) loaded.add(attachment);
                    }
                } else if (data.getData() != null) {
                    Attachment attachment = readAttachment(data.getData(), 1);
                    if (attachment != null) loaded.add(attachment);
                }
                main.post(() -> {
                    pendingAttachments.clear();
                    pendingAttachments.addAll(loaded);
                    updateAttachmentText();
                    setLoading(false, loaded.isEmpty() ? "No file" : loaded.size() + " file");
                });
            } catch (Exception error) {
                String message = error.getMessage() == null ? "Could not read attachment" : error.getMessage();
                main.post(() -> setLoading(false, message));
            }
        });
    }

    private Attachment readAttachment(Uri uri, int index) throws Exception {
        if (uri == null) return null;
        String name = attachmentName(uri, index);
        String mimeType = getContentResolver().getType(uri);
        if (mimeType == null || mimeType.trim().isEmpty()) mimeType = "application/octet-stream";
        try (InputStream stream = getContentResolver().openInputStream(uri)) {
            if (stream == null) return null;
            byte[] buffer = new byte[8192];
            java.io.ByteArrayOutputStream output = new java.io.ByteArrayOutputStream();
            int total = 0;
            int read;
            while ((read = stream.read(buffer)) != -1) {
                total += read;
                if (total > MAX_ATTACHMENT_BYTES) {
                    throw new IllegalArgumentException(name + " is larger than 10 MB");
                }
                output.write(buffer, 0, read);
            }
            Attachment attachment = new Attachment();
            attachment.name = name;
            attachment.mimeType = mimeType;
            attachment.dataBase64 = Base64.encodeToString(output.toByteArray(), Base64.NO_WRAP);
            return attachment;
        }
    }

    private String attachmentName(Uri uri, int index) {
        String fallback = "attachment-" + index;
        try (Cursor cursor = getContentResolver().query(uri, null, null, null, null)) {
            if (cursor != null && cursor.moveToFirst()) {
                int nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (nameIndex >= 0) {
                    String name = cursor.getString(nameIndex);
                    if (name != null && !name.trim().isEmpty()) return name;
                }
            }
        } catch (Exception ignored) {
        }
        String last = uri.getLastPathSegment();
        return last == null || last.trim().isEmpty() ? fallback : last;
    }

    private void updateAttachmentText() {
        if (attachmentText == null) return;
        if (pendingAttachments.isEmpty()) {
            attachmentText.setText("0 files");
            return;
        }
        if (pendingAttachments.size() == 1) {
            attachmentText.setText(pendingAttachments.get(0).name);
            return;
        }
        attachmentText.setText(pendingAttachments.size() + " files");
    }

    private void postSimple(String path, String busyText, boolean refreshAfter) {
        setLoading(true, busyText + "...");
        postJson(path, new JSONObject(), new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                setLoading(false, json.optString("message", "Done"));
                if (refreshAfter) refreshProfiles(false);
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
    }

    private void logout() {
        String token = sessionToken;
        Runnable clearLocal = () -> {
            sessionToken = "";
            signedInUser = "";
            prefs.edit().remove("sessionToken").remove("signedInUser").apply();
            renderAuthState();
        };
        if (token.isEmpty()) {
            clearLocal.run();
            return;
        }
        setLoading(true, "Logging out...");
        postJson("/auth/logout", new JSONObject(), new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                clearLocal.run();
            }

            @Override
            public void onError(String message) {
                clearLocal.run();
            }
        });
    }

    private void postProfile(Profile profile, String action, String path) {
        setLoading(true, action + " " + profile.displayName + "...");
        postJson(path, new JSONObject(), new JsonCallback() {
            @Override
            public void onSuccess(JSONObject json) {
                setLoading(false, json.optString("message", "Done"));
                selectedProfileId = profile.id;
                selectedProfileName = profile.displayName;
                prefs.edit().putString("selectedProfileId", selectedProfileId).putString("selectedProfileName", selectedProfileName).apply();
                updateSelectedText();
                refreshProfiles(false);
            }

            @Override
            public void onError(String message) {
                setLoading(false, message);
            }
        });
    }

    private void getJson(String path, JsonCallback callback) {
        request("GET", path, null, callback);
    }

    private void postJson(String path, JSONObject payload, JsonCallback callback) {
        request("POST", path, payload, callback);
    }

    private void request(String method, String path, JSONObject payload, JsonCallback callback) {
        String baseUrl = cleanBaseUrl();
        if (baseUrl.isEmpty()) {
            callback.onError("Missing Mac URL");
            return;
        }
        if (!isAllowedBridgeUrl(baseUrl)) {
            callback.onError("Use HTTPS for remote URLs. Plain HTTP is only allowed for localhost, private LAN IPs, or .local hosts.");
            return;
        }
        network.execute(() -> {
            HttpURLConnection connection = null;
            try {
                URL url = new URL(baseUrl + path);
                connection = (HttpURLConnection) url.openConnection();
                connection.setRequestMethod(method);
                connection.setConnectTimeout(6500);
                connection.setReadTimeout(readTimeoutFor(path));
                connection.setRequestProperty("Accept", "application/json");
                String accessClientId = prefs.getString("cfAccessClientId", "").trim();
                String accessClientSecret = prefs.getString("cfAccessClientSecret", "").trim();
                if (!accessClientId.isEmpty() && !accessClientSecret.isEmpty()) {
                    connection.setRequestProperty("CF-Access-Client-Id", accessClientId);
                    connection.setRequestProperty("CF-Access-Client-Secret", accessClientSecret);
                }
                if (!sessionToken.isEmpty()) {
                    connection.setRequestProperty("Authorization", "Bearer " + sessionToken);
                }
                if (payload != null) {
                    byte[] bytes = payload.toString().getBytes(StandardCharsets.UTF_8);
                    connection.setDoOutput(true);
                    connection.setRequestProperty("Content-Type", "application/json; charset=utf-8");
                    connection.setFixedLengthStreamingMode(bytes.length);
                    try (OutputStream out = connection.getOutputStream()) {
                        out.write(bytes);
                    }
                }
                int code = connection.getResponseCode();
                InputStream stream = code >= 200 && code < 300 ? connection.getInputStream() : connection.getErrorStream();
                String body = readAll(stream);
                if (code < 200 || code >= 300) {
                    String message = body.isEmpty() ? ("HTTP " + code) : new JSONObject(body).optString("error", "HTTP " + code);
                    main.post(() -> callback.onError(message));
                    return;
                }
                JSONObject json = body.isEmpty() ? new JSONObject() : new JSONObject(body);
                main.post(() -> callback.onSuccess(json));
            } catch (Exception error) {
                String friendly = friendlyNetworkError(error, baseUrl);
                main.post(() -> callback.onError(friendly));
            } finally {
                if (connection != null) connection.disconnect();
            }
        });
    }

    private String readAll(InputStream stream) throws Exception {
        if (stream == null) return "";
        StringBuilder builder = new StringBuilder();
        try (BufferedReader reader = new BufferedReader(new InputStreamReader(stream, StandardCharsets.UTF_8))) {
            String line;
            while ((line = reader.readLine()) != null) {
                builder.append(line);
            }
        }
        return builder.toString();
    }

    private void saveConnection() {
        prefs.edit()
            .putString("baseUrl", cleanBaseUrl())
            .putString("cfAccessClientId", accessClientIdInput == null ? prefs.getString("cfAccessClientId", "") : accessClientIdInput.getText().toString().trim())
            .putString("cfAccessClientSecret", accessClientSecretInput == null ? prefs.getString("cfAccessClientSecret", "") : accessClientSecretInput.getText().toString().trim())
            .apply();
    }

    private String cleanBaseUrl() {
        String text = urlInput.getText().toString().trim();
        if (!text.isEmpty() && !text.contains("://")) {
            text = "http://" + text;
        }
        while (text.endsWith("/")) text = text.substring(0, text.length() - 1);
        try {
            URL url = new URL(text);
            StringBuilder builder = new StringBuilder();
            builder.append(url.getProtocol()).append("://").append(url.getHost());
            if (url.getPort() > 0) {
                builder.append(":").append(url.getPort());
            }
            return builder.toString();
        } catch (Exception ignored) {
        }
        return text;
    }

    private String friendlyNetworkError(Exception error, String baseUrl) {
        String raw = error.getMessage() == null ? "Connection failed" : error.getMessage();
        String lower = raw.toLowerCase(Locale.US);
        if (lower.contains("failed to connect")
            || lower.contains("connection refused")
            || lower.contains("timed out")
            || lower.contains("no route")
            || lower.contains("unable to resolve host")) {
            return "Cannot reach Mac bridge at " + baseUrl
                + ". Start Bridge on the Mac, then use the LAN URL.";
        }
        return raw;
    }

    private int readTimeoutFor(String path) {
        if (path == null) return 15000;
        if (path.startsWith("/codex/ask")) return 30 * 60 * 1000;
        if (path.startsWith("/vps/sync")) return 3 * 60 * 1000;
        if (path.contains("/open") || path.equals("/send") || path.equals("/sync") || path.equals("/share-all")) return 90000;
        if (path.equals("/close-all")) return 45000;
        if (path.startsWith("/codex/conversations") && selectedTarget.equals("vps")) return 9000;
        return 15000;
    }

    private String connectionHelp(String message) {
        if (message == null || message.trim().isEmpty()) {
            return "Bridge offline. Start it on the Mac.";
        }
        return message;
    }

    private boolean isAllowedBridgeUrl(String baseUrl) {
        try {
            URL url = new URL(baseUrl);
            String scheme = url.getProtocol() == null ? "" : url.getProtocol().toLowerCase(Locale.US);
            if ("https".equals(scheme)) return true;
            if (!"http".equals(scheme)) return false;

            String host = url.getHost() == null ? "" : url.getHost().toLowerCase(Locale.US);
            return isLocalOrPrivateHost(host);
        } catch (Exception ignored) {
            return false;
        }
    }

    private boolean isLocalOrPrivateHost(String host) {
        if (host.equals("localhost") || host.endsWith(".local") || host.equals("::1") || host.startsWith("fe80:")) {
            return true;
        }
        String[] parts = host.split("\\.");
        if (parts.length != 4) return false;
        try {
            int a = Integer.parseInt(parts[0]);
            int b = Integer.parseInt(parts[1]);
            for (String part : parts) {
                int value = Integer.parseInt(part);
                if (value < 0 || value > 255) return false;
            }
            return a == 10
                || a == 127
                || (a == 169 && b == 254)
                || (a == 172 && b >= 16 && b <= 31)
                || (a == 192 && b == 168);
        } catch (NumberFormatException ignored) {
            return false;
        }
    }

    private void setLoading(boolean loading, String message) {
        connectionProgress.setVisibility(loading ? View.VISIBLE : View.GONE);
        statusText.setText(message);
    }

    private boolean isLoading() {
        return connectionProgress != null && connectionProgress.getVisibility() == View.VISIBLE;
    }

    private void showEmptyProfiles(String message) {
        profileList.removeAllViews();
        TextView empty = label(message, 14, Color.argb(190, 230, 239, 242), false);
        empty.setPadding(dp(4), dp(20), dp(4), dp(18));
        empty.setGravity(Gravity.CENTER);
        profileList.addView(empty, matchWrap());
    }

    private void showEmptyConversations(String message) {
        if (conversationList == null) return;
        conversationList.removeAllViews();
        TextView empty = label(message, 14, Color.argb(190, 230, 239, 242), false);
        empty.setPadding(dp(4), dp(20), dp(4), dp(18));
        empty.setGravity(Gravity.CENTER);
        conversationList.addView(empty, matchWrap());
    }

    private void updateSelectedText() {
        if (selectedText == null) return;
        String profile = selectedProfileId.isEmpty() ? "No account" : selectedProfileName;
        String conversation = selectedSessionId.isEmpty() ? "No thread" : selectedConversationTitle;
        selectedText.setText(targetName() + " · " + profile + " · " + conversation);
    }

    private boolean isSelected(Profile profile) {
        return profile.id.equals(selectedProfileId);
    }

    private String shortHome(String home) {
        if (home == null || home.isEmpty()) return "";
        if (home.length() <= 44) return home;
        return "..." + home.substring(home.length() - 41);
    }

    private String enc(String value) {
        try {
            return URLEncoder.encode(value, "UTF-8").replace("+", "%20");
        } catch (Exception ignored) {
            return value;
        }
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }

    private LinearLayout vertical() {
        LinearLayout view = new LinearLayout(this);
        view.setOrientation(LinearLayout.VERTICAL);
        return view;
    }

    private TextView sectionTitle(String text) {
        TextView title = label(text, 18, Color.WHITE, true);
        title.setPadding(0, 0, 0, dp(12));
        return title;
    }

    private TextView label(String text, int sp, int color, boolean bold) {
        TextView view = new TextView(this);
        view.setText(text);
        view.setTextSize(sp);
        view.setTextColor(color);
        view.setIncludeFontPadding(true);
        view.setFontFeatureSettings("kern");
        if (bold) view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        return view;
    }

    private TextView chip(String text, int color, int fill) {
        TextView chip = label(text, 13, color, true);
        chip.setPadding(dp(12), dp(7), dp(12), dp(7));
        chip.setBackground(roundDrawable(fill, 999, Color.argb(72, Color.red(color), Color.green(color), Color.blue(color)), 1));
        return chip;
    }

    private EditText input(String hint) {
        EditText input = new EditText(this);
        input.setTextColor(Color.WHITE);
        input.setHintTextColor(Color.argb(145, 220, 232, 238));
        input.setTextSize(14);
        input.setSingleLine(true);
        input.setHint(hint);
        input.setPadding(dp(14), dp(12), dp(14), dp(12));
        input.setBackground(roundDrawable(Color.argb(44, 255, 255, 255), 16, Color.argb(56, 255, 255, 255), 1));
        return input;
    }

    private Button actionButton(String text, int accent) {
        Button button = new Button(this);
        button.setAllCaps(false);
        button.setText(text);
        button.setTextSize(14);
        button.setTextColor(Color.WHITE);
        button.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        button.setPadding(dp(12), dp(8), dp(12), dp(8));
        button.setMinHeight(0);
        button.setMinimumHeight(0);
        styleActionButton(button, accent, 18);
        return button;
    }

    private void styleActionButton(Button button, int accent, int radius) {
        button.setTextColor(Color.WHITE);
        button.setBackground(buttonDrawable(accent, radius));
    }

    private Button tileButton(String text, int accent, View.OnClickListener listener) {
        Button button = actionButton(text, accent);
        button.setOnClickListener(listener);
        button.setGravity(Gravity.CENTER);
        return button;
    }

    private Button smallButton(String text, int accent) {
        Button button = actionButton(text, accent);
        button.setTextSize(12);
        button.setMinWidth(dp(80));
        return button;
    }

    private Button iconButton(String text, int accent) {
        Button button = actionButton(text, accent);
        button.setTextSize(24);
        button.setMinWidth(0);
        return button;
    }

    private GradientDrawable buttonDrawable(int accent, int radius) {
        GradientDrawable drawable = new GradientDrawable(GradientDrawable.Orientation.LEFT_RIGHT, new int[]{
            Color.argb(105, Color.red(accent), Color.green(accent), Color.blue(accent)),
            Color.argb(58, Color.red(accent), Color.green(accent), Color.blue(accent))
        });
        drawable.setCornerRadius(dp(radius));
        drawable.setStroke(dp(1), Color.argb(110, Color.red(accent), Color.green(accent), Color.blue(accent)));
        return drawable;
    }

    private GradientDrawable roundDrawable(int fill, int radius, int stroke, int strokeWidth) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        drawable.setStroke(dp(strokeWidth), stroke);
        return drawable;
    }

    private Space space(int dp) {
        Space space = new Space(this);
        space.setLayoutParams(new LinearLayout.LayoutParams(1, dp(dp)));
        return space;
    }

    private Space spaceH(int dp) {
        Space space = new Space(this);
        space.setLayoutParams(new LinearLayout.LayoutParams(dp(dp), 1));
        return space;
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(-1, -2);
    }

    private LinearLayout.LayoutParams wrapWrap() {
        return new LinearLayout.LayoutParams(-2, -2);
    }

    private LinearLayout.LayoutParams weightedButton() {
        return new LinearLayout.LayoutParams(0, dp(46), 1);
    }

    private GridLayout.LayoutParams gridCell() {
        GridLayout.LayoutParams params = new GridLayout.LayoutParams();
        params.width = 0;
        params.height = dp(48);
        params.columnSpec = GridLayout.spec(GridLayout.UNDEFINED, 1f);
        params.setMargins(dp(4), dp(4), dp(4), dp(4));
        return params;
    }

    private int dp(float value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private Accent profileAccent(Profile profile) {
        if ("login_needed".equals(profile.authStatus)) {
            return new Accent(Color.argb(115, 255, 184, 61), Color.argb(36, 255, 184, 61));
        }
        int hash = Math.abs(profile.id.hashCode());
        int[] strokes = {Color.rgb(40, 242, 210), Color.rgb(72, 192, 255), Color.rgb(97, 211, 91), Color.rgb(255, 184, 61)};
        int stroke = strokes[hash % strokes.length];
        return new Accent(Color.argb(112, Color.red(stroke), Color.green(stroke), Color.blue(stroke)), Color.argb(34, Color.red(stroke), Color.green(stroke), Color.blue(stroke)));
    }

    private interface JsonCallback {
        void onSuccess(JSONObject json);
        void onError(String message);
    }

    private static final class Profile {
        String id = "";
        String displayName = "";
        String home = "";
        String authStatus = "";
        String quota = "";
        String reset = "";
    }

    private static final class Conversation {
        String id = "";
        String title = "";
        String updatedAt = "";
        String projectLabel = "";
        String source = "";
    }

    private static final class Attachment {
        String name = "";
        String mimeType = "";
        String dataBase64 = "";
    }

    private static final class Accent {
        final int stroke;
        final int fill;

        Accent(int stroke, int fill) {
            this.stroke = stroke;
            this.fill = fill;
        }
    }

    private static final class QuotaPart {
        String label;
        int percent;
        String meta;

        int goodColor() {
            if (percent >= 70) return Color.rgb(97, 211, 91);
            if (percent >= 30) return Color.rgb(40, 242, 210);
            return Color.rgb(255, 69, 92);
        }

        static List<QuotaPart> parse(String quota, String reset) {
            List<QuotaPart> parts = new ArrayList<>();
            if (quota == null || quota.trim().isEmpty() || quota.contains("unknown") || quota.equals("unlimited")) {
                return parts;
            }
            String[] quotaParts = quota.split("/");
            for (String part : quotaParts) {
                String[] bits = part.trim().split("\\s+");
                if (bits.length < 2 || !bits[1].endsWith("%")) continue;
                QuotaPart q = new QuotaPart();
                q.label = bits[0].toUpperCase(Locale.US);
                try {
                    q.percent = Integer.parseInt(bits[1].replace("%", ""));
                } catch (Exception ignored) {
                    q.percent = 0;
                }
                q.meta = bits[1];
                String resetMeta = resetForLabel(reset, q.label);
                if (!resetMeta.isEmpty()) q.meta = resetMeta;
                parts.add(q);
            }
            return parts;
        }

        static String resetForLabel(String reset, String label) {
            if (reset == null) return "";
            for (String part : reset.split("/")) {
                String trimmed = part.trim();
                if (trimmed.toUpperCase(Locale.US).startsWith(label.toUpperCase(Locale.US) + " ")) {
                    return trimmed.substring(label.length()).trim();
                }
            }
            return "";
        }
    }

    private static final class AuroraBackgroundView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);

        AuroraBackgroundView(Context context) {
            super(context);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            int w = getWidth();
            int h = getHeight();
            paint.setShader(new LinearGradient(0, 0, w, h, new int[]{
                Color.rgb(4, 13, 18),
                Color.rgb(9, 30, 36),
                Color.rgb(22, 17, 31),
                Color.rgb(4, 12, 17)
            }, null, Shader.TileMode.CLAMP));
            canvas.drawRect(0, 0, w, h, paint);

            drawGlow(canvas, w * 0.16f, h * 0.08f, Math.max(w, h) * 0.30f, Color.argb(42, 40, 242, 210));
            drawGlow(canvas, w * 0.90f, h * 0.24f, Math.max(w, h) * 0.24f, Color.argb(34, 255, 105, 55));
            paint.setShader(null);
        }

        private void drawGlow(Canvas canvas, float cx, float cy, float radius, int color) {
            paint.setShader(new RadialGradient(cx, cy, radius, color, Color.TRANSPARENT, Shader.TileMode.CLAMP));
            canvas.drawCircle(cx, cy, radius, paint);
        }
    }

    private final class GlassPanel extends FrameLayout {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final int radius;
        private final int stroke;
        private final int glow;

        GlassPanel(Context context, int radiusDp, int stroke, int glow) {
            super(context);
            setWillNotDraw(false);
            this.radius = dp(radiusDp);
            this.stroke = stroke;
            this.glow = glow;
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float r = radius;
            paint.setStyle(Paint.Style.FILL);
            paint.setShader(new LinearGradient(0, 0, getWidth(), getHeight(), new int[]{
                Color.argb(84, 255, 255, 255),
                Color.argb(33, 255, 255, 255),
                glow
            }, null, Shader.TileMode.CLAMP));
            canvas.drawRoundRect(0, 0, getWidth(), getHeight(), r, r, paint);

            paint.setShader(null);
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(dp(1));
            paint.setColor(stroke);
            canvas.drawRoundRect(dp(0.5f), dp(0.5f), getWidth() - dp(0.5f), getHeight() - dp(0.5f), r, r, paint);
            super.onDraw(canvas);
        }
    }

    private final class AvatarView extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final String letter;
        private final int start;
        private final int end;

        AvatarView(Context context, String name) {
            super(context);
            String clean = name == null || name.trim().isEmpty() ? "C" : name.trim();
            letter = clean.substring(0, 1).toUpperCase(Locale.US);
            int hash = Math.abs(clean.hashCode());
            int[][] palettes = {
                {Color.rgb(31, 224, 190), Color.rgb(67, 156, 255)},
                {Color.rgb(128, 88, 255), Color.rgb(51, 232, 180)},
                {Color.rgb(255, 111, 57), Color.rgb(255, 190, 48)},
                {Color.rgb(44, 168, 255), Color.rgb(39, 240, 207)}
            };
            start = palettes[hash % palettes.length][0];
            end = palettes[hash % palettes.length][1];
        }

        @Override
        protected void onDraw(Canvas canvas) {
            float r = Math.min(getWidth(), getHeight()) * 0.22f;
            paint.setShader(new LinearGradient(0, 0, getWidth(), getHeight(), start, end, Shader.TileMode.CLAMP));
            paint.setStyle(Paint.Style.FILL);
            canvas.drawRoundRect(0, 0, getWidth(), getHeight(), r, r, paint);
            paint.setShader(null);
            paint.setColor(Color.WHITE);
            paint.setTextAlign(Paint.Align.CENTER);
            paint.setTypeface(Typeface.create(Typeface.DEFAULT, Typeface.BOLD));
            paint.setTextSize(getHeight() * 0.45f);
            Paint.FontMetrics fm = paint.getFontMetrics();
            float y = getHeight() / 2f - (fm.ascent + fm.descent) / 2f;
            canvas.drawText(letter, getWidth() / 2f, y, paint);
        }
    }
}
