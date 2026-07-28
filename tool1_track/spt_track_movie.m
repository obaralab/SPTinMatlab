function ctl = spt_track_movie(parent)
%SPT_TRACK_MOVIE  Embeddable player: animate tracks over the SPT frames with ER/mito overlays.
%
%   ctl = spt_track_movie(parent)   builds the player UI into container `parent`
%   ctl.load(R, sel)                point it at tracks (sel = TRACK_IDs to draw); R = [] clears
%   ctl.stop()                      stop + delete the playback timer (call this on app close)
%
% R needs: sptPath, base, x/y (1-based px), frame (0-based), trackId; optional erPath/mitoPath.
% Controls: play/pause, a frame scrubber, a "trails" toggle, ER + mito overlay toggles (enabled
% only when that segmentation exists for the cell), and "Save video…" (MPEG-4, AVI fallback). The
% playback timer is owned here and torn down via ctl.stop().

% ---- state (persists across the nested callbacks) ----
R = []; sel = []; S = struct('x',{},'y',{},'f',{}); K = 0;
f0 = 1; f1 = 1; cur = 1; nfr = 1; lo = 0; hi = 1; cols = lines(8);   % nfr = true movie length (promoted from load_ so draw()/seek() can see it)
haveEr = false; haveMi = false; erFg = 1; miFg = 1; erNfr = 0; miNfr = 0;
erCol = [0.15 0.9 0.35]; erA = 0.28; miCol = [1 0.25 0.75]; miA = 0.42;
tmr = []; playing = false;
hImg = []; hTrail = gobjects(0); hHead = gobjects(0); hCS = gobjects(0);
zoomBox = []; imgH = 1; imgW = 1;   % zoomBox = [xlo xhi ylo yhi] px framing the CS + played tracks

% ---- UI ----
g  = uigridlayout(parent, [2 1], 'RowHeight', {'1x', 34}, 'Padding', [0 0 0 0], 'RowSpacing', 4);
ax = uiaxes(g); ax.Toolbar.Visible = 'on'; title(ax, 'run or pick a cell, then Play random tracks');   % toolbar on → pan/zoom/home for manual zoom-out
cr = uigridlayout(g, [1 10], 'ColumnWidth', {84, '1x', 86, 48, 52, 40, 46, 40, 92, 'fit'}, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
btnP  = uibutton(cr, 'Text', '▶ Play', 'ButtonPushedFcn', @(s,e) toggle());
sld   = uislider(cr, 'Limits', [1 2], 'Value', 1, 'MajorTicks', [], 'ValueChangedFcn', @(s,e) seek(round(s.Value)));
lblF  = uilabel(cr, 'Text', '', 'HorizontalAlignment', 'center');
chkT  = uicheckbox(cr, 'Text', 'trails', 'Value', true, 'ValueChangedFcn', @(s,e) draw());
chkZ  = uicheckbox(cr, 'Text', 'zoom', 'Value', true, 'ValueChangedFcn', @(s,e) applyZoom(), 'FontColor', [0.20 0.40 0.72], ...
                   'Tooltip', 'Zoom to the contact site + played tracks. Uncheck for the full frame; the axes toolbar (top-right on hover) pans/zooms further.');
chkER = uicheckbox(cr, 'Text', 'ER',   'Value', false, 'Enable', 'off', 'ValueChangedFcn', @(s,e) draw(), 'FontColor', [0.10 0.55 0.20]);
chkMi = uicheckbox(cr, 'Text', 'mito', 'Value', false, 'Enable', 'off', 'ValueChangedFcn', @(s,e) draw(), 'FontColor', [0.80 0.15 0.55]);
chkCS = uicheckbox(cr, 'Text', 'CS',   'Value', false, 'Enable', 'off', 'ValueChangedFcn', @(s,e) draw(), 'FontColor', [0.80 0.62 0.05]);
btnS  = uibutton(cr, 'Text', 'Save video…', 'Enable', 'off', 'ButtonPushedFcn', @(s,e) saveVid());
uilabel(cr, 'Text', '');   % spacer

ctl = struct('load', @load_, 'stop', @stopAll, 'axes', ax, 'saveVideo', @saveVid);

    function load_(Rin, selIn)
        stopT();
        R = Rin;
        if isempty(R) || ~isstruct(R) || ~isfield(R,'sptPath') || ~isfile(R.sptPath), clearView(); return; end
        sel = selIn(:).'; K = numel(sel);
        tid = R.trackId; S = struct('x',{},'y',{},'f',{}); f0 = inf; f1 = -inf;
        for j = 1:K
            r = find(tid == sel(j)); [~, o] = sort(R.frame(r)); r = r(o);
            S(j).x = R.x(r); S(j).y = R.y(r); S(j).f = R.frame(r) + 1;   % 0-based frame -> 1-based
            if ~isempty(r), f0 = min(f0, S(j).f(1)); f1 = max(f1, S(j).f(end)); end
        end
        if ~isfinite(f0), clearView(); return; end
        info = imfinfo(R.sptPath); nfr = numel(info); f0 = max(1, f0); f1 = min(nfr, f1);
        imgH = info(1).Height; imgW = info(1).Width;
        midf = round((f0 + f1) / 2); im0 = double(imread(R.sptPath, midf));
        lo = prctile(im0(:), 1); hi = prctile(im0(:), 99.8); if ~(hi > lo), hi = lo + 1; end
        cols = lines(max(K, 1));
        haveEr = isfield(R,'erPath')   && ~isempty(R.erPath)   && isfile(R.erPath);
        haveMi = isfield(R,'mitoPath') && ~isempty(R.mitoPath) && isfile(R.mitoPath);
        erNfr = 0; miNfr = 0;
        if haveEr, ei = imfinfo(R.erPath);   erNfr = numel(ei); erFg = segFg_(R.erPath);   end
        if haveMi, mi = imfinfo(R.mitoPath); miNfr = numel(mi); miFg = segFg_(R.mitoPath); end
        chkER.Enable = onoff_(haveEr); if ~haveEr, chkER.Value = false; end
        chkMi.Enable = onoff_(haveMi); if ~haveMi, chkMi.Value = false; end
        btnS.Enable = 'on';
        sld.Limits = [1 max(nfr, 2)]; sld.Value = f0; cur = f0;   % scrub the WHOLE movie; start at the tracks' first frame
        cla(ax);
        hImg = imshow(composite(cur), 'Parent', ax); hold(ax, 'on');
        hTrail = gobjects(1, K); hHead = gobjects(1, K);
        for j = 1:K
            hTrail(j) = plot(ax, nan, nan, '-', 'Color', cols(j,:), 'LineWidth', 1.3);
            hHead(j)  = plot(ax, nan, nan, 'o', 'MarkerFaceColor', cols(j,:), 'MarkerEdgeColor', 'k', 'MarkerSize', 5);
        end
        % static contact-site outline (px), toggled by the CS checkbox — like the ER/mito overlays
        hCS = gobjects(0);
        haveCS = isfield(R,'csPolyPx') && ~isempty(R.csPolyPx) && size(R.csPolyPx,1) >= 3;
        if haveCS
            hCS = plot(ax, R.csPolyPx(:,1), R.csPolyPx(:,2), '-', 'Color', [1 0.9 0.15], 'LineWidth', 1.6, 'Visible', onoff_(chkCS.Value));
        end
        chkCS.Enable = onoff_(haveCS); if ~haveCS, chkCS.Value = false; end
        hold(ax, 'off');
        title(ax, sprintf('%s — %d tracks · track span %d–%d of %d frames', R.base, K, f0, f1, nfr));
        computeZoomBox();
        draw(); applyZoom(); startT(); btnP.Text = '⏸ Pause'; playing = true;
    end

    function computeZoomBox()
        % Frame the contact-site outline (if any) + every played track's localizations, as a square
        % px box with a margin. Static for the load so the view doesn't jitter during playback.
        zoomBox = [];
        xs = []; ys = [];
        for j = 1:K, xs = [xs; S(j).x(:)]; ys = [ys; S(j).y(:)]; end %#ok<AGROW>
        if isfield(R,'csPolyPx') && ~isempty(R.csPolyPx) && size(R.csPolyPx,1) >= 3
            xs = [xs; R.csPolyPx(:,1)]; ys = [ys; R.csPolyPx(:,2)];
        end
        ok = isfinite(xs) & isfinite(ys); xs = xs(ok); ys = ys(ok);
        if isempty(xs), return; end
        cx = (min(xs)+max(xs))/2; cy = (min(ys)+max(ys))/2;
        half = max(max(xs)-min(xs), max(ys)-min(ys)) / 2;   % square, sized by the larger extent
        half = max(half*1.25, 18);                          % 25% margin; floor ~18 px so a tiny site isn't over-zoomed
        zoomBox = [cx-half, cx+half, cy-half, cy+half];
    end

    function applyZoom()
        % Zoom checkbox ON → clamp the axes to zoomBox; OFF → the full frame. (Manual toolbar
        % pan/zoom overrides until the next toggle or load.)
        if isempty(hImg) || ~isvalid(hImg) || ~isvalid(ax), return; end
        full = true;
        if ~isempty(zoomBox) && chkZ.Value
            xl = [max(0.5, zoomBox(1)), min(imgW+0.5, zoomBox(2))];
            yl = [max(0.5, zoomBox(3)), min(imgH+0.5, zoomBox(4))];
            if xl(2) > xl(1) && yl(2) > yl(1), xlim(ax, xl); ylim(ax, yl); full = false; end
        end
        if full, xlim(ax, [0.5, imgW+0.5]); ylim(ax, [0.5, imgH+0.5]); end   % full frame (or a box that clamped to nothing)
    end

    function clearView()
        cla(ax); title(ax, 'run or pick a cell, then Play random tracks'); hCS = gobjects(0); zoomBox = [];
        btnS.Enable = 'off'; chkER.Enable = 'off'; chkMi.Enable = 'off'; chkCS.Enable = 'off';
        lblF.Text = ''; playing = false; btnP.Text = '▶ Play';
    end

    function tick()
        if ~isvalid(ax), stopT(); return; end
        cur = cur + 1; if cur > f1 || cur < f0, cur = f0; end   % playback loops the track span (Play stays useful)
        sld.Value = min(max(cur, 1), nfr); draw();
    end

    function toggle()
        if isempty(R), return; end
        if playing, stopT(); btnP.Text = '▶ Play';  playing = false;
        else,       startT(); btnP.Text = '⏸ Pause'; playing = true; end
    end

    function seek(fr), cur = min(max(fr, 1), nfr); draw(); end   % manual scrub across the whole movie

    function draw()
        if isempty(hImg) || ~isvalid(hImg), return; end
        hImg.CData = composite(cur);
        showTrail = chkT.Value;
        for j = 1:K
            m = S(j).f <= cur;
            if showTrail && any(m), set(hTrail(j), 'XData', S(j).x(m), 'YData', S(j).y(m));
            else,                   set(hTrail(j), 'XData', nan,       'YData', nan); end
            he = find(S(j).f == cur, 1);           % current spot, else last one before now
            if isempty(he), he = find(m, 1, 'last'); end
            if isempty(he), set(hHead(j), 'XData', nan,        'YData', nan);
            else,           set(hHead(j), 'XData', S(j).x(he), 'YData', S(j).y(he)); end
        end
        if ~isempty(hCS) && all(isvalid(hCS)), set(hCS, 'Visible', onoff_(chkCS.Value)); end   % static CS outline toggle
        lblF.Text = sprintf('frame %d/%d', cur, nfr);
        drawnow limitrate;
    end

    function rgb = composite(fr)
        g0 = mat2gray(double(imread(R.sptPath, fr)), [lo hi]);
        rgb = repmat(g0, [1 1 3]); [Hh, Ww] = size(g0);
        if haveEr && chkER.Value && fr <= erNfr
            e = imread(R.erPath, fr) == erFg;
            if isequal(size(e), [Hh Ww]), rgb = tint_(rgb, e, erCol, erA); end
        end
        if haveMi && chkMi.Value && fr <= miNfr
            mm = imread(R.mitoPath, fr) == miFg;
            if isequal(size(mm), [Hh Ww]), rgb = tint_(rgb, mm, miCol, miA); end
        end
    end

    function saveVid(outPath)
        if isempty(R), return; end
        if nargin < 1 || isempty(outPath)
            [fn, pp] = uiputfile({'*.mp4', 'MPEG-4 video'}, 'Save track video', sprintf('%s_tracks.mp4', R.base));
            if isequal(fn, 0), return; end
            outPath = fullfile(pp, fn);
        end
        wasPlaying = playing; stopT();
        out = outPath;
        try,   vw = VideoWriter(out, 'MPEG-4');
        catch, [pd, b] = fileparts(out); vw = VideoWriter(fullfile(pd, [b '.avi']), 'Motion JPEG AVI'); end
        vw.FrameRate = 12; open(vw);
        tmpp = [tempname '.png']; saved = cur; ok = true; sz = []; nF = f1 - f0 + 1;
        sTxt = btnS.Text; btnS.Enable = 'off';
        try
            for fr = f0:f1
                cur = fr; draw();
                btnS.Text = sprintf('Saving %d/%d…', fr-f0+1, nF);
                exportgraphics(ax, tmpp, 'Resolution', 110);
                im = imread(tmpp);
                if isempty(sz)                                   % lock every frame to the FIRST frame's EVEN size:
                    hh = size(im,1); ww = size(im,2);            % H.264 requires even dims, and exportgraphics can
                    sz = [hh - mod(hh,2), ww - mod(ww,2)];       % drift ±1 px between frames (the "Frame must be W by H" error)
                end
                if size(im,1) ~= sz(1) || size(im,2) ~= sz(2), im = imresize(im, sz); end
                writeVideo(vw, im);
            end
        catch ME
            ok = false; errMsg = ME.message;
        end
        close(vw); if isfile(tmpp), delete(tmpp); end
        btnS.Text = sTxt; btnS.Enable = 'on';
        cur = saved; draw(); if wasPlaying, startT(); end
        % a notification failure (e.g. headless) must not undo a completed save
        if ok, try, uialert(ancestor(ax,'figure'), sprintf('Saved %s', vw.Filename), 'Video saved', 'Icon', 'success'); catch, end
        else,  try, uialert(ancestor(ax,'figure'), errMsg, 'Save failed'); catch, end, end
    end

    function startT()
        if isempty(tmr) || ~isvalid(tmr)
            tmr = timer('ExecutionMode', 'fixedRate', 'Period', 0.08, 'BusyMode', 'drop', 'TimerFcn', @(~,~) tick());
        end
        if strcmp(tmr.Running, 'off'), start(tmr); end
    end

    function stopT()
        try, if ~isempty(tmr) && isvalid(tmr) && strcmp(tmr.Running, 'on'), stop(tmr); end, catch, end
    end

    function stopAll()
        try, if ~isempty(tmr) && isvalid(tmr), stop(tmr); delete(tmr); end, catch, end
        tmr = []; playing = false;
    end
end

% -------------------------------------------------------------------------
function rgb = tint_(rgb, mask, col, a)
if ~any(mask(:)), return; end
for c = 1:3
    ch = rgb(:,:,c); ch(mask) = (1-a)*ch(mask) + a*col(c); rgb(:,:,c) = ch;
end
end

function fg = segFg_(segPath)
a = imread(segPath, 1); v = unique(a(:)); nz = v(v > 0);
fg = 1; if ~isempty(nz), fg = min(nz); end
end

function s = onoff_(tf), if tf, s = 'on'; else, s = 'off'; end, end
