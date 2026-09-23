function api = spt_compare_tab(parent, ctx)
%SPT_COMPARE_TAB  Tool 3's Compare tab: the mapped sites and their dwell events, grouped and tested.
%
%   api = spt_compare_tab(parent, ctx)
%
% Built into `parent` (the tab), and it keeps its own state - the loaded copies of the mapper and
% dwell results it is comparing, the filters, the table and the two axes. Everything it needs from
% the rest of the tool arrives in CTX, so this file can be read, changed and tested on its own:
%
%   ctx.anaDir()          the project's analysis folder (creating it, and persisting the build)
%   ctx.ensureCSW()       load analysis/CSW_final.mat into the session if it is not there; true if ready
%   ctx.ensureDD()        the same for the dwell results
%   ctx.csw()  ctx.dd()   what those loaded: the mapper's site-windows, and the dwell struct
%   ctx.exptCtl()         the Experiment tab's controller (conditions per cell), or []
%   ctx.matched()         the matched-files table, for the cell list
%   ctx.siteTrackStats(e) per-member-track % inside for one site-window (the Sites tab's own measure)
%
% api: .setCells(cells)  .cellList()  .load()   - the hooks the app's headless tests drive.
%
% It reads the shared state and never writes it: comparing must not change what is being compared.

% ---- the tab's own state --------------------------------------------------------------------
axCmpCdf=[]; axCmpScatter=[]; cmpCSW=[]; cmpCells={}; cmpDD=[]; cmpKeptSites=[]; cmpLast=[];
ddCmpData=[]; ddCmpGroup=[]; ddCmpMetric=[]; ddCmpSites=[]; eCmpMinDw=[]; lblCmp=[]; tblCmp=[];

buildCompareTab(parent);
api = struct('setCells', @setCompareCells, 'cellList', @compareCellList, 'load', @ensureCompareData);

    % ================= Tab 8 · Compare (grouped stats: mito / window / condition) =================
    function buildCompareTab(parent)
        % The status line gets its OWN full-width row. It was sharing the control row, and every
        % filter added since has taken width off it — it was down to ~150 px for a string that runs
        % past 700 when a crossed grouping lists a test per condition. Wrapping in its own row it
        % has the whole tab, and the controls stop competing with it for space.
        g = uigridlayout(parent,[3 1],'RowHeight',{34,30,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 15],'ColumnWidth',{40,150, 62, 54,146, 40,100, 44,60, 46,140, 84, 80, 92, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',7);
        uilabel(r,'Text','data','HorizontalAlignment','right');
        ddCmpData = uidropdown(r,'Items',{'current project','experiment (all folders)'},'Value','current project', ...
            'Tooltip','Compare THIS project''s sites, or the whole EXPERIMENT (every folder in the Experiment tab, grouped by the conditions you assigned).');
        uibutton(r,'Text','cells…','ButtonPushedFcn',@(s,e) onCompareCellPick(), ...
            'Tooltip',['Choose which CELLS enter the comparison. Every cell is in by default; ' ...
            'unticking one leaves it out of every group, of both plots and of the exports. Use it ' ...
            'to drop a cell you do not trust without editing the experiment manifest — the ' ...
            'Experiment tab''s exclude flag is the durable QC judgement, this is a per-comparison one.']);
        uilabel(r,'Text','group by','HorizontalAlignment','right');
        ddCmpGroup = uidropdown(r,'Items',{'mito vs non-mito','window (time-resolved)','condition', ...
            'condition x mito','window x mito'},'Value','condition', ...
            'Tooltip','The "x mito" groupings split each condition (or window) into its mito and non-mito sites, so you compare the two INSIDE a condition instead of pooling them.');
        % WHICH sites enter the comparison, applied BEFORE grouping. Grouping by condition with this
        % on 'mito only' is the cross-condition mito comparison — WT vs FFAT vs … over mito sites —
        % which the crossed grouping cannot give you: that one pairs mito against non-mito INSIDE a
        % condition and interleaves the conditions.
        uilabel(r,'Text','sites','HorizontalAlignment','right');
        ddCmpSites = uidropdown(r,'Items',{'all sites','mito only','non-mito only'},'Value','all sites', ...
            'Tooltip','Restrict the comparison to mito or non-mito sites before grouping. The table, the scatter, the dwell-time distribution and the tests all honour it.');
        % Spurious-hit gate, on EVERY metric. dw% is the picker's own site statistic — the median,
        % over the site's member tracks, of each track's % of window localizations inside the
        % footprint. A site whose tracks merely cross it scores low; a real one scores high. This
        % drops the site outright, so enrichment, area and n_loc are filtered by it as much as dwell.
        uilabel(r,'Text','dw% ≥','HorizontalAlignment','right');
        eCmpMinDw = uispinner(r,'Limits',[0 100],'Value',0,'Step',5,'RoundFractionalValues',true, ...
            'Tooltip',['Drop sites whose dw% is below this — dw% is the MEDIAN over the site''s member ' ...
            'tracks of the % of each track''s window localizations inside the footprint, the same ' ...
            'number the picker''s site table shows. Low dw% = traffic passing through, which is what a ' ...
            'spurious hit looks like. 0 = keep every site. Applies to every metric, and a dropped ' ...
            'site takes its dwell events out of the distribution with it.']);
        uilabel(r,'Text','metric','HorizontalAlignment','right');
        ddCmpMetric = uidropdown(r,'Items',{'dwell s','k_out /s','enrichment','area µm²','n_loc','mito fraction','# sites'},'Value','enrichment');
        uibutton(r,'Text','▶ Compute','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w','ButtonPushedFcn',@(s,e) onCompareCompute());
        uibutton(r,'Text','Export CSV','ButtonPushedFcn',@(s,e) onCompareExport(), ...
            'Tooltip','The SUMMARY table as shown: one row per group with n, mean, sem, median and mode.');
        uibutton(r,'Text','Export points','ButtonPushedFcn',@(s,e) onComparePointsExport(), ...
            'Tooltip',['Every per-site value behind the table, for Prism: one COLUMN per group, ' ...
            'rows padded — paste straight into a Prism Column data table. Also writes a long-format ' ...
            'file with each point''s cell/site/window/condition for traceability, and the pooled ' ...
            'dwell EVENT durations per group when dwell is loaded (that is what the CDF is drawn from).']);
        uilabel(r,'Text','');
        % WordWrap stays: even at full width a crossed grouping over many conditions can run past
        % one line, and the end of a status line is where the p-values are.
        lblCmp = uilabel(g,'Text','Run the mapper (Sites tab); dwell metrics also need the Dwell tab. Then Compute.', ...
            'FontColor',[0.2 0.4 0.5],'WordWrap','on');
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'0.9x','1.1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        tblCmp = uitable(mn,'ColumnName',{'group','n','mean','sem','median','mode'}, ...
            'ColumnWidth',{'1x',40,64,58,64,64});
        rc = uigridlayout(mn,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axCmpScatter = uiaxes(rc); title(axCmpScatter,'per-site values by group');
        axCmpCdf     = uiaxes(rc); title(axCmpCdf,'pooled dwell-time CDF');
        spt_axes_policy([axCmpScatter axCmpCdf]);
    end

    function tf = cellKeep(e)
        tf = isempty(cmpCells) || any(strcmp(cmpCells, cellKey(e)));
    end

    function k = cellKey(rec)
        % A CELL is (source folder, cell file). The folder matters: two days can hold a cell of the
        % same name, and they are different cells.
        fo = ''; if isfield(rec,'srcFolder') && ~isempty(rec.srcFolder), fo = char(rec.srcFolder); end
        k = sprintf('%s|%s', fo, char(fieldOr(rec,'file')));
    end

    function [keys, labs] = compareCellList()
        % Every cell present in the loaded dataset, with the condition it was assigned, in a stable
        % order. Built from the SITES, so a cell in the manifest that the mapper never reached does
        % not appear — there is nothing of it to include or leave out.
        keys = {}; labs = {};
        for i = 1:numel(cmpCSW)
            k = cellKey(cmpCSW(i));
            if any(strcmp(keys,k)), continue; end
            e = cmpCSW(i);
            cond = ''; if isfield(e,'condition') && ~isempty(e.condition), cond = [' · ' char(e.condition)]; end
            nS = sum(arrayfun(@(x) strcmp(cellKey(x),k), cmpCSW));
            keys{end+1} = k; %#ok<AGROW>
            labs{end+1} = sprintf('%s%s  (%d sites)', char(fieldOr(e,'file')), cond, nS); %#ok<AGROW>
        end
        [keys, ord] = sort(keys); labs = labs(ord);
    end

    function [vals, grp, base, ismito, keptIdx] = compareValues(metric, mode)
        % One value per site (cmpCSW element) + its group label. Dwell/k_out from cmpDD.perSite,
        % ctx.matched() on site IDENTITY (see findPerSite), so colliding siteUIDs across an experiment's
        % folders cannot pull another condition's dwell number onto this site.
        % base/ismito are the label's two parts, kept so a crossed grouping can pair and test them.
        n = numel(cmpCSW); vals = nan(1,n); grp = cell(1,n); base = cell(1,n); ismito = false(1,n);
        keptIdx = 1:n;                                    % trimmed with the rest by keep, below
        havePS = ~isempty(cmpDD) && isfield(cmpDD,'perSite') && ~isempty(cmpDD.perSite);
        cmpKeptSites = containers.Map('KeyType','char','ValueType','logical');
        for i = 1:n
            e = cmpCSW(i);
            [lab, bs, im] = groupLabel(e, mode);
            if ~cellKeep(e) || ~siteKeep(im) || ~dwKeep(e), continue; end   % grp{i} stays '' -> dropped below
            cmpKeptSites(siteKey(e)) = true;
            grp{i} = lab; base{i} = bs; ismito(i) = im;
            switch metric
                case 'enrichment', vals(i) = e.enrichment;
                case 'area µm²',   vals(i) = e.areaUm2;
                case 'n_loc',      vals(i) = e.nMemberLocs;
                case 'mito fraction', vals(i) = double(cs_site_near(e,'mito'));
                case '# sites',    vals(i) = 1;
                case {'dwell s','k_out /s'}
                    if havePS
                        j = findPerSite(cmpDD.perSite, e);
                        if j>0
                            if strcmp(metric,'dwell s'), vals(i) = cmpDD.perSite(j).meanDwell;
                            else,                        vals(i) = cmpDD.perSite(j).kout; end
                        end
                    end
            end
        end
        keep = ~cellfun(@isempty,grp);
        vals = vals(keep); grp = grp(keep); base = base(keep); ismito = ismito(keep);
        keptIdx = keptIdx(keep);
    end

    function tf = crossedMito(mode)
        tf = any(strcmp(mode, {'condition x mito','window x mito'}));
    end

    function tf = dwKeep(e)
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m <= 0, tf = true; return; end                 % 0 keeps every site, NaN dw% included
        p = siteDwPct(e); tf = isfinite(p) && p >= m;
    end

    function t = dwellTag(metric)
        % A dwell number computed over only the dwelling tracks is a different measurement from one
        % over every member, and nothing on this tab would otherwise say which you are looking at.
        t = '';
        if ~any(strcmp(metric,{'dwell s','k_out /s'})), return; end
        if isempty(cmpDD) || ~isfield(cmpDD,'minPctInside'), return; end
        mp = cmpDD.minPctInside;
        if isscalar(mp)
            if mp > 0, t = sprintf(' · dwell from tracks ≥%g%% inside', mp); end
        elseif numel(mp) > 1
            t = sprintf(' · ⚠ folders used different ≥%% inside thresholds (%s) — recompute dwell consistently', ...
                strjoin(arrayfun(@(v) sprintf('%g',v), mp(:)', 'uni',0), ', '));
        end
    end

    function ok = ensureCompareData(metric)
        % Load what Compute would compare — this project, or the whole experiment — into
        % cmpCSW/cmpDD, reporting any reason it cannot into the status line. Shared with the cell
        % picker, so the picker can only ever offer cells the comparison would actually read.
        ok = false;
        useExpt = ~isempty(ddCmpData) && isgraphics(ddCmpData) && startsWith(ddCmpData.Value,'experiment');
        if useExpt
            cellsE = []; if ~isempty(ctx.exptCtl()) && isstruct(ctx.exptCtl()), cellsE = ctx.exptCtl().getCells(); end
            if isempty(cellsE), lblCmp.Text='No experiment loaded — add folders + conditions in the Experiment tab first.'; return; end
            [cmpCSW, cmpDD] = cs_experiment_aggregate(ctx.exptCtl().getManifest());
            if isempty(cmpCSW), lblCmp.Text='No mapped sites in the experiment folders (run the mapper per folder).'; return; end
        else
            if ~ctx.ensureCSW(), lblCmp.Text='Run the mapper (Sites tab) first.'; return; end
            cmpCSW = ctx.csw(); cmpDD = ctx.dd();
            if any(strcmp(metric,{'dwell s','k_out /s'})) && ~ctx.ensureDD(), lblCmp.Text='Compute dwell (Dwell tab) first for this metric.'; return; end
            cmpDD = ctx.dd();
        end
        if any(strcmp(metric,{'dwell s','k_out /s'})) && (isempty(cmpDD) || ~isfield(cmpDD,'perSite') || isempty(cmpDD.perSite))
            lblCmp.Text = ['This metric needs dwell — compute dwell (Dwell tab)' tern(useExpt,' in each experiment folder.','.')]; return;
        end
        ok = true;
    end

    function p = filterParts()
        % The active site filters, in words. One list, so the axes title, the status line and the
        % "nothing survived" message cannot describe the same filtering differently.
        p = {};
        if ~strcmp(siteFilter(),'all sites'), p{end+1} = siteFilter(); end
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m > 0, p{end+1} = sprintf('dw%% ≥ %g%%', m); end
        if ~isempty(cmpCells), p{end+1} = sprintf('%d cells', numel(cmpCells)); end
    end

    function t = filterTag()
        % '' when nothing is filtered, so titles and file names of an unfiltered run are unchanged.
        t = ''; p = filterParts(); if ~isempty(p), t = [' — ' strjoin(p,', ')]; end
    end

    function t = filterTok()
        % The same two filters as a file-name token, so no two different comparisons can land on
        % one file. Empty when nothing is filtered, leaving old names untouched.
        t = '';
        if ~strcmp(siteFilter(),'all sites'), t = ['_' regexprep(siteFilter(),'\W','_')]; end
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m > 0, t = sprintf('%s_dw%g', t, m); end
        % The cell selection needs a token that DISTINGUISHES selections, not just marks that one
        % exists: two different sets of the same size would otherwise overwrite each other's export.
        if ~isempty(cmpCells)
            h = 0; for c = double(strjoin(sort(cmpCells),'|')), h = mod(h*31 + c, 1679616); end
            t = sprintf('%s_cells%d_%s', t, numel(cmpCells), lower(dec2base(h,36,4)));
        end
    end

    function j = findPerSite(ps, e)
        % Match a site to its per-site dwell record on IDENTITY — source folder, file, cell, site and
        % window — not on siteUID alone. siteUID restarts at 1 in every folder's mapper run, so across
        % an experiment the ids collide; the old fall-throughs handed back a record from a DIFFERENT
        % folder, which under a by-condition grouping silently scores one condition with another's
        % dwell. No identity match now means NO value (NaN, dropped from the group) — the honest
        % answer when a folder was never dwelled.
        j = 0;
        for c = find([ps.siteUID] == e.siteUID)
            if sameSiteRec(ps(c), e), j = c; return; end
        end
    end

    function dv = groupDwell(gname, mode)
        % Pooled event dwell durations for the events whose group label == gname (works on either the
        % project or the experiment dataset — events carry window/mito/condition directly). The
        % sites filter is applied HERE too: a 'mito only' table above a distribution pooling every
        % event would be two different comparisons drawn as one figure.
        dv = [];
        if isempty(cmpDD) || ~isfield(cmpDD,'events') || isempty(cmpDD.events), return; end
        ev = cmpDD.events;
        % Keep an event only if ITS SITE survived the filters. Re-testing the event against each
        % filter would work for mito but not for dw%, which is a property of the site, not of the
        % event — and two gates evaluated separately are two gates that can disagree.
        if ~isempty(cmpKeptSites)
            ev = ev(arrayfun(@(x) isKey(cmpKeptSites, siteKey(x)), ev));
        end
        if isempty(ev), return; end
        labs = arrayfun(@(x) groupLabel(x,mode), ev, 'uni',0);
        dv = [ev(strcmp(labs,gname)).dwell];
    end

    function [lab, base, ismito] = groupLabel(e, mode)
        % Label for ONE record — a ctx.csw() site OR a dwell event. Both spell the mito flag in a form
        % cs_site_near reads (MitoFlag on sites, mito on events), so one function serves both and the
        % table, the CDF and the tests cannot drift apart in how they name a group.
        ismito = cs_site_near(e,'mito');
        switch mode
            case {'window (time-resolved)','window x mito'}, base = sprintf('win %d', e.window);
            case {'condition','condition x mito'}
                if isfield(e,'condition') && ~isempty(e.condition), base = char(e.condition); else, base = e.file; end
            otherwise,                     base = tern(ismito,'mito','non-mito');
        end
        lab = base;
        if crossedMito(mode), lab = [base ' · ' tern(ismito,'mito','non-mito')]; end
    end

    function onCompareCellPick()
        if ~ensureCompareData('enrichment'), return; end     % a metric that never demands dwell
        [keys, labs] = compareCellList();
        if isempty(keys), lblCmp.Text = 'No cells in the loaded data yet — run the mapper first.'; return; end
        sel = true(numel(keys),1);
        if ~isempty(cmpCells), sel = ismember(keys(:), cmpCells(:)); end

        d = uifigure('Name','Cells in the comparison','Position',[120 120 470 470],'WindowStyle','modal');
        d.UserData = false;                                   % set by OK; closing the window cancels
        d.CloseRequestFcn = @(s,e) uiresume(d);
        gg = uigridlayout(d,[3 1],'RowHeight',{34,'1x',32},'Padding',[10 10 10 10],'RowSpacing',6);
        uilabel(gg,'Text','Untick a cell to leave it out of every group, both plots and the exports.', ...
            'WordWrap','on','FontColor',[0.2 0.4 0.5]);
        tb = uitable(gg,'Data',table(sel, labs(:), 'VariableNames',{'use','cell'}), ...
            'ColumnEditable',[true false],'ColumnWidth',{44,'1x'});
        br = uigridlayout(gg,[1 5],'ColumnWidth',{64,64,'1x',80,80},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(br,'Text','All','ButtonPushedFcn',@(s,e) setAll(tb,true));
        uibutton(br,'Text','None','ButtonPushedFcn',@(s,e) setAll(tb,false));
        uilabel(br,'Text','');
        uibutton(br,'Text','Cancel','ButtonPushedFcn',@(s,e) uiresume(d));
        uibutton(br,'Text','OK','FontWeight','bold','ButtonPushedFcn',@(s,e) pickOk(d));
        uiwait(d);
        if ~isgraphics(d), return; end
        if d.UserData
            v = logical(tb.Data.use);
            if all(v), setCompareCells([]); else, setCompareCells(keys(v)); end
            lblCmp.Text = sprintf('%d of %d cells selected — press Compute.', nnz(v), numel(keys));
        end
        delete(d);
    end

    function onCompareCompute()
        metric = ddCmpMetric.Value; mode = ddCmpGroup.Value;
        if ~ensureCompareData(metric), return; end
        [vals, grp, base, ismito, keptIdx] = compareValues(metric, mode);   % per-site value + label (+ its two parts)
        if isempty(vals)
            % Distinguish "this metric has no values" from "your filters removed every site" — the
            % second is a knob to turn, and the generic message sent you looking for a broken stage.
            fp = filterParts();
            if isempty(fp)
                lblCmp.Text = 'No values for this metric/grouping.';
            else
                lblCmp.Text = sprintf(['No sites left after filtering (%s) — %d before. Loosen it. ' ...
                    '(A site with no tracked member track has no dw%% at all, so any dw%% ≥ above 0 drops it.)'], ...
                    strjoin(fp,', '), numel(cmpCSW));
            end
            return;
        end
        [gnames,~,gi] = unique(grp,'stable'); gi = reshape(gi,size(vals));
        % A group counts as mito when EVERY site in it is — true of a crossed group's mito half, of
        % the 'mito' group of a plain mito/non-mito split, and of every group once the sites filter
        % is on 'mito only'. All three then get the mito colour, from one rule.
        gmito = false(1,numel(gnames));
        for j = 1:numel(gnames), gmito(j) = all(ismito(gi==j)); end
        if crossedMito(mode)
            % Base groups keep their first-seen order, but each one's mito row is placed next to its
            % own non-mito row: the pair you are actually comparing has to be adjacent in the table
            % and on the axes, otherwise a 4-condition split reads as 8 unrelated bars.
            [~,~,bi] = unique(base,'stable');
            key = zeros(numel(gnames),2);
            for j = 1:numel(gnames), k1 = find(gi==j,1); key(j,:) = [bi(k1), double(~gmito(j))]; end
            [~,ord] = sortrows(key);
            gnames = gnames(ord); gmito = gmito(ord);
            remap = zeros(1,numel(ord)); remap(ord) = 1:numel(ord); gi = reshape(remap(gi),size(gi));
        end
        D = cell(numel(gnames),6);
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            D(j,:) = {gnames{j}, sprintf('%d',numel(v)), sprintf('%.4g',mean0(v)), sprintf('%.4g',semv(v)), ...
                      sprintf('%.4g',med0(v)), sprintf('%.4g',modev(v))};
        end
        tblCmp.Data = D;
        % scatter of per-site values by group (+ mean marker). An all-mito group's dots take the
        % app's pinned mito magenta (darkened to read on a white axes) so the two halves of a
        % condition are told apart by colour, not just by the tick label.
        cMito = [0.85 0.25 0.80]; cNon = [0.45 0.55 0.75];
        cla(axCmpScatter); hold(axCmpScatter,'on');
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            xj = j + 0.12*(rand(numel(v),1)-0.5)*2;
            cj = cNon; if gmito(j), cj = cMito; end
            plot(axCmpScatter, xj, v, 'o','MarkerFaceColor',cj,'MarkerEdgeColor','none','MarkerSize',4);
            plot(axCmpScatter, j, mean0(v), '_','Color',[0.85 0.25 0.2],'MarkerSize',26,'LineWidth',2);
        end
        hold(axCmpScatter,'off'); xlim(axCmpScatter,[0.5 numel(gnames)+0.5]);
        xticks(axCmpScatter,1:numel(gnames)); xticklabels(axCmpScatter,gnames);
        xtickangle(axCmpScatter, tern(numel(gnames)>4, 30, 0));
        ylabel(axCmpScatter, metric); title(axCmpScatter, sprintf('%s by %s%s', metric, mode, filterTag()));
        % pooled dwell CDF per group (from the selected dataset's dwell events)
        cla(axCmpCdf);
        if ~isempty(cmpDD) && isfield(cmpDD,'events') && ~isempty(cmpDD.events)
            hold(axCmpCdf,'on'); leg = {};
            for j = 1:numel(gnames)
                dv = groupDwell(gnames{j}, mode); dv = dv(isfinite(dv)&dv>0);
                if isempty(dv), continue; end
                sv = sort(dv(:)); yy = (1:numel(sv))'/numel(sv);
                stairs(axCmpCdf, sv, yy, 'LineWidth',1.3);
                % n and median in the legend: the curves are the comparison, and a distribution
                % read off a figure is worth little without the count behind it.
                leg{end+1} = sprintf('%s (n=%d, med %.3g s)', gnames{j}, numel(sv), median(sv)); %#ok<AGROW>
            end
            hold(axCmpCdf,'off'); xlabel(axCmpCdf,'dwell (s)'); ylabel(axCmpCdf,'CDF');
            if ~isempty(leg), legend(axCmpCdf, leg, 'Location','southeast'); end
            title(axCmpCdf, ['pooled dwell-time CDF' filterTag()]);
        else
            title(axCmpCdf,'pooled dwell-time CDF (compute dwell in the Dwell tab)');
        end
        % rank-sum p (Stats toolbox): two groups get the one test; a crossed grouping gets mito vs
        % non-mito WITHIN each condition/window, which is the comparison that grouping is asking for.
        pmsg = '';
        if crossedMito(mode) && exist('ranksum','file')==2
            ub = unique(base,'stable'); parts = {};
            for b = 1:numel(ub)
                sel = strcmp(base, ub{b});
                v1 = vals(sel &  ismito); v1 = v1(isfinite(v1));
                v2 = vals(sel & ~ismito); v2 = v2(isfinite(v2));
                if isempty(v1) || isempty(v2), continue; end
                try, parts{end+1} = sprintf('%s p=%.3g', ub{b}, ranksum(v1,v2)); catch, end %#ok<AGROW>
            end
            if ~isempty(parts), pmsg = [' · mito vs non-mito ' strjoin(parts,', ')]; end
        end
        % Falls through to here for a plain grouping — and for a crossed one the sites filter has
        % collapsed to a single side, where there is no pair left to test.
        if isempty(pmsg) && numel(gnames)==2 && exist('ranksum','file')==2
            v1 = vals(gi==1); v2 = vals(gi==2); v1=v1(isfinite(v1)); v2=v2(isfinite(v2));
            if ~isempty(v1)&&~isempty(v2), try, pmsg = sprintf(' · rank-sum p=%.3g', ranksum(v1,v2)); catch, end, end
        elseif isempty(pmsg) && numel(gnames)>2 && exist('kruskalwallis','file')==2
            % More than two groups is the cross-condition case. A rank-sum needs a pair, so the
            % omnibus goes first: does ANY group differ? Chase it with pairwise tests yourself —
            % this deliberately does not print six uncorrected p-values as if they were one result.
            ok = isfinite(vals);
            if numel(unique(gi(ok)))>2
                try, pmsg = sprintf(' · Kruskal-Wallis p=%.3g (omnibus)', kruskalwallis(vals(ok), gi(ok), 'off')); catch, end
            end
        end
        % The per-point export writes THIS result, not a recomputation: an export that re-derives its
        % own values can silently disagree with the table the user is looking at.
        cmpLast = struct('metric',metric, 'mode',mode, 'vals',vals, 'gi',gi, 'idx',keptIdx, ...
                         'gnames',{gnames}, 'ismito',ismito);
        lblCmp.Text = sprintf('%s by %s%s · %d groups%s%s', metric, mode, filterTag(), numel(gnames), pmsg, dwellTag(metric));
    end

    function onCompareExport()
        if isempty(tblCmp) || isempty(tblCmp.Data), lblCmp.Text='Nothing to export — Compute first.'; return; end
        anaDir = ctx.anaDir(); if isempty(anaDir), return; end
        % The filter is part of the file name: a mito-only comparison and an all-sites one of the
        % same metric and grouping are different results, and must not overwrite each other.
        grpTok = [regexprep(ddCmpGroup.Value,'\W','_') filterTok()];
        fn = fullfile(anaDir, sprintf('cs_compare_%s_by_%s.csv', regexprep(ddCmpMetric.Value,'\W','_'), grpTok));
        try
            fid = fopen(fn,'w'); fprintf(fid,'group,n,mean,sem,median,mode\n');
            D = tblCmp.Data;
            for r = 1:size(D,1)
                fprintf(fid,'%s,%s,%s,%s,%s,%s\n', csvq(D{r,1}), D{r,2}, D{r,3}, D{r,4}, D{r,5}, D{r,6});
            end
            fclose(fid); lblCmp.Text = ['Exported ' fn];
        catch ME, lblCmp.Text = ['Export failed: ' ME.message]; end
    end

    function onComparePointsExport()
        % Every per-site value behind the table, in the shape Prism wants: one COLUMN per group,
        % rows padded to the longest. Plus a long-format companion carrying each point's identity
        % (cell, site, window, condition, mito, dw%), because a bare column of numbers cannot be
        % traced back to the site it came from — and, when dwell events are loaded, the pooled event
        % durations per group, which is what the CDF is drawn from and what a distribution figure in
        % Prism needs (the per-site column holds one mean per site, not the events).
        if isempty(cmpLast) || isempty(cmpLast.vals), lblCmp.Text='Nothing to export — Compute first.'; return; end
        anaDir = ctx.anaDir(); if isempty(anaDir), return; end
        L = cmpLast;
        stem = sprintf('%s_by_%s%s', regexprep(L.metric,'\W','_'), regexprep(L.mode,'\W','_'), filterTok());
        written = {};
        try
            % (1) wide — one column per group, for a Prism Column data table
            cols = cell(1,numel(L.gnames));
            for j = 1:numel(L.gnames)
                v = L.vals(L.gi==j); cols{j} = v(isfinite(v));
            end
            fw = fullfile(anaDir, ['cs_points_' stem '.csv']);
            writeWideCSV(fw, L.gnames, cols); written{end+1} = fw;

            % (2) long — one row per point, with where it came from
            fl = fullfile(anaDir, ['cs_points_' stem '_long.csv']);
            fid = fopen(fl,'w');
            fprintf(fid,'group,condition,file,cellIndex,csID,window,siteUID,mito,dw_pct,%s\n', ...
                regexprep(L.metric,'\W','_'));
            for k = 1:numel(L.vals)
                if ~isfinite(L.vals(k)), continue; end
                e = cmpCSW(L.idx(k));
                cond = ''; if isfield(e,'condition') && ~isempty(e.condition), cond = char(e.condition); end
                fprintf(fid,'%s,%s,%s,%d,%d,%d,%d,%d,%.4g,%.6g\n', ...
                    csvq(L.gnames{L.gi(k)}), csvq(cond), csvq(char(fieldOr(e,'file'))), ...
                    num0(fieldOr(e,'cellIndex')), num0(fieldOr(e,'csID')), num0(fieldOr(e,'window')), ...
                    num0(fieldOr(e,'siteUID')), double(L.ismito(k)), siteDwPct(e), L.vals(k));
            end
            fclose(fid); written{end+1} = fl;

            % (3) the events behind the CDF, same wide shape — only when there are any
            if ~isempty(cmpDD) && isfield(cmpDD,'events') && ~isempty(cmpDD.events)
                ecols = cell(1,numel(L.gnames)); any_ = false;
                for j = 1:numel(L.gnames)
                    dv = groupDwell(L.gnames{j}, L.mode); dv = dv(isfinite(dv) & dv>0);
                    ecols{j} = dv(:); any_ = any_ || ~isempty(dv);
                end
                if any_
                    fe = fullfile(anaDir, sprintf('cs_dwellevents_by_%s%s.csv', ...
                        regexprep(L.mode,'\W','_'), filterTok()));
                    writeWideCSV(fe, L.gnames, ecols); written{end+1} = fe;
                end
            end
            [~,n1] = fileparts(written{1});
            lblCmp.Text = sprintf('Exported %d file(s) to %s — %s.csv + %d more', ...
                numel(written), anaDir, n1, numel(written)-1);
        catch ME
            lblCmp.Text = ['Point export failed: ' ME.message];
        end
    end

    function pickOk(d), d.UserData = true; uiresume(d); end

    function tf = sameSiteRec(a, b)
        % Same physical site-window in both records. srcFolder exists only on the experiment
        % aggregate; within one project file/cell/site/window is already unique.
        tf = strcmp(char(fieldOr(a,'file')), char(fieldOr(b,'file'))) ...
            && isequal(fieldOr(a,'cellIndex'), fieldOr(b,'cellIndex')) ...
            && isequal(fieldOr(a,'csID'),      fieldOr(b,'csID')) ...
            && isequal(fieldOr(a,'window'),    fieldOr(b,'window'));
        if tf && isfield(a,'srcFolder') && isfield(b,'srcFolder')
            tf = strcmp(char(a.srcFolder), char(b.srcFolder));
        end
    end

    function setAll(tb, v), D = tb.Data; D.use(:) = v; tb.Data = D; end

    % ---- shared downstream helpers ----

    function setCompareCells(sel)
        % Headless hook (spt_compare_group_smoke) and the picker's commit path. [] or every key
        % means "all cells", which is the state that leaves file names and titles unfiltered.
        if isempty(sel), cmpCells = []; return; end
        cmpCells = cellstr(sel(:)');
    end

    function pct = siteDwPct(e)
        % dw%: the MEDIAN over the site's member tracks of each track's % of window localizations
        % inside the footprint — the picker's own site statistic. NaN when the site has no tracked
        % member at all, which no positive threshold should pass: a site with nothing tracked in it
        % has produced no evidence of dwelling, and that is what the gate is asking for.
        pct = NaN;
        if ~isstruct(e) || ~isfield(e,'tracks') || isempty(e.tracks), return; end
        v = ctx.siteTrackStats(e); v = v(isfinite(v));
        if ~isempty(v), pct = median(v); end
    end

    function v = siteFilter()
        v = 'all sites';
        if ~isempty(ddCmpSites) && isgraphics(ddCmpSites), v = ddCmpSites.Value; end
    end

    function tf = siteKeep(ismito)
        % The 'sites' filter, applied to a site OR to a dwell event — both know their mito flag, so
        % the table and the dwell-time distribution below it cannot end up filtered differently.
        switch siteFilter()
            case 'mito only',     tf = ismito;
            case 'non-mito only', tf = ~ismito;
            otherwise,            tf = true;
        end
    end

    function k = siteKey(rec)
        % One identity for a site-window, spelled the same on a ctx.csw() record and on a dwell event, so
        % a filter decided over sites can be applied to events. srcFolder is '' outside an
        % experiment aggregate, where file/cell/site/window is already unique.
        fo = ''; if isfield(rec,'srcFolder') && ~isempty(rec.srcFolder), fo = char(rec.srcFolder); end
        k = sprintf('%s|%s|%d|%d|%d', fo, char(fieldOr(rec,'file')), ...
            num0(fieldOr(rec,'cellIndex')), num0(fieldOr(rec,'csID')), num0(fieldOr(rec,'window')));
    end
end

% ================================ local helpers =================================
function s = csvq(t)
% One CSV field, quoted — a condition named "WT, day 2" must not become two columns.
t = char(t);
if any(t == ',') || any(t == '"') || any(t == newline)
    s = ['"' strrep(t,'"','""') '"'];
else
    s = t;
end
end

function v = fieldOr(s, f)
% struct field s.(f) if present and a struct, else [] — so QC survives structs without erDist/MSD.
if isstruct(s) && isfield(s,f), v = s.(f); else, v = []; end
end

function m = mean0(v)
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; else, m = mean(v); end
end

function m = med0(v)
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; else, m = median(v); end
end

function m = modev(v)
% Modal value as the CENTRE OF THE BUSIEST HISTOGRAM BIN, not MATLAB's mode().
%
% mode() answers "which value occurs most often", which is the wrong question for a continuous
% sample: per-site enrichment, area and mean-dwell are all distinct to many decimal places, no
% value repeats, and mode() then returns the SMALLEST one — a number that looks like a statistic
% and is really just the minimum. Binning first is what makes a mode mean anything here.
%
% Bin width by Freedman-Diaconis (2*IQR/n^(1/3)) — IQR-based, so the long right tail that dwell
% times always have cannot inflate it the way a std-based rule would; Scott's rule as the fallback
% when the IQR is zero, and the median when there is nothing to bin at all.
%
% A binned mode DEPENDS ON THE BIN WIDTH. Read it as "where the bulk of the distribution sits",
% cross-checked against the CDF, and do not quote it as a precise value.
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; return; end
if numel(v) < 3 || (max(v)-min(v)) <= 0, m = median(v); return; end
w = 2*(pct0(v,75)-pct0(v,25)) / numel(v)^(1/3);            % Freedman-Diaconis
if ~(w > 0), w = 3.49*std(v)/numel(v)^(1/3); end           % Scott
if ~(w > 0), m = median(v); return; end
edges = min(v):w:(max(v)+w);
if numel(edges) < 2, m = median(v); return; end
[cnt, e] = histcounts(v, edges);
[~, i] = max(cnt);
m = (e(i) + e(i+1))/2;
end

function n = num0(v)
% a scalar numeric for a key, whatever a missing or odd field turns up as
if isempty(v) || ~isnumeric(v), n = 0; else, n = double(v(1)); end
end

function s = semv(v)
v = v(:); v = v(isfinite(v));
if numel(v) < 2, s = 0; else, s = std(v)/sqrt(numel(v)); end
end

function y = tern(c, a, b)
if c, y = a; else, y = b; end
end

function writeWideCSV(path, names, cols)
% One column per group, rows padded to the longest with empty fields — a Prism Column data table.
% Prism reads ragged columns this way; a long format would need pivoting before it could be plotted
% as "scatter with mean", which is the figure these numbers are for.
fid = fopen(path,'w');
if fid < 0, error('cannot write %s', path); end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', strjoin(cellfun(@csvq, names(:)', 'uni',0), ','));
nMax = max(cellfun(@numel, cols));
for r = 1:nMax
    f = cell(1,numel(cols));
    for j = 1:numel(cols)
        if r <= numel(cols{j}), f{j} = sprintf('%.6g', cols{j}(r)); else, f{j} = ''; end
    end
    fprintf(fid, '%s\n', strjoin(f, ','));
end
end

function q = pct0(v, p)
% p-th percentile without the Statistics toolbox — prctile's midpoint convention (order statistics
% at (i-0.5)/n, linearly interpolated), so modev's bin width matches what prctile would give.
v = sort(v(:)); n = numel(v);
if n == 0, q = NaN; return; end
if n == 1, q = v(1); return; end
x = p/100*n - 0.5;
if x <= 0,   q = v(1); return; end
if x >= n-1, q = v(n); return; end
i = floor(x); f = x - i;
q = v(i+1)*(1-f) + v(i+2)*f;
end
