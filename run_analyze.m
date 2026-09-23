function run_analyze()
%RUN_ANALYZE  The old name for Tool 4 — "Contact Sites" (see run_contactsites).
%   The toolkit used to have three parts, with everything past the build in one "Analyze" tool.
%   Building and QC are now their own tool (run_analysis, Tool 3) and the contact-site work is
%   Tool 4. This name still opens the contact-site tool, so existing notes and scripts keep working.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
run_contactsites();
end
