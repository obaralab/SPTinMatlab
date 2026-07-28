function S = cs_step_import(anaDir)
%CS_STEP_IMPORT  Read STEP pointwise-diffusion predictions back into per-member-track results.
%
%   S = cs_step_import(anaDir)   % reads analysis/step/step_predictions.csv (from run_step.py)
%
% Returns a struct array, one per member track, with the pointwise D(t)/alpha(t) and the key readout:
% the diffusion coefficient INSIDE the contact site vs OUTSIDE it — i.e. whether the molecule's motion
% changes due to the interaction. Din/Dout are medians; ratio = Din/Dout (<1 = slower inside).
%
% S(k): track_uid, file, csID, window, trackCol, frame, D, alpha, inside(logical),
%       Din, Dout, ratio, nIn, nOut, method
f = fullfile(anaDir,'step','step_predictions.csv');
assert(isfile(f), 'cs_step_import: %s not found — export tracks + run run_step.py first.', f);
T = readtable(f, 'Delimiter', ',');
uids = unique(T.track_uid, 'stable');
S = repmat(struct('track_uid','','file','','csID',NaN,'window',NaN,'trackCol',NaN, ...
    'frame',[],'D',[],'alpha',[],'inside',[],'Din',NaN,'Dout',NaN,'ratio',NaN,'nIn',0,'nOut',0,'method',''), numel(uids), 1);
hasMethod = ismember('method', T.Properties.VariableNames);
for k = 1:numel(uids)
    m = strcmp(T.track_uid, uids{k});
    fr = T.frame(m); D = dcol(T.D(m)); al = dcol(T.alpha(m)); ins = logical(T.inside_cs(m));
    tok = regexp(char(uids{k}), '^(.*)__cs(\d+)_w(\d+)_t(\d+)$', 'tokens', 'once');
    Din  = median(D(ins  & isfinite(D)), 'omitnan');
    Dout = median(D(~ins & isfinite(D)), 'omitnan');
    S(k).track_uid = char(uids{k});
    if ~isempty(tok)
        S(k).file = tok{1}; S(k).csID = str2double(tok{2}); S(k).window = str2double(tok{3}); S(k).trackCol = str2double(tok{4});
    end
    S(k).frame = fr; S(k).D = D; S(k).alpha = al; S(k).inside = ins;
    S(k).Din = Din; S(k).Dout = Dout; S(k).ratio = Din/Dout;
    S(k).nIn = nnz(ins); S(k).nOut = nnz(~ins);
    if hasMethod, mm = T.method(m); S(k).method = char(string(mm(1))); end
end
end

% -------------------------------------------------------------------------
function v = dcol(c)
% a CSV column that may have blank cells -> double with NaN for blanks
if isnumeric(c), v = double(c); else, v = str2double(string(c)); end
end
