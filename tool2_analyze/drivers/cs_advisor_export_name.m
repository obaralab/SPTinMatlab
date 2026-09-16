function name = cs_advisor_export_name(name)
%CS_ADVISOR_EXPORT_NAME  A typed export name made safe to use as ONE folder name.
%
%   name = cs_advisor_export_name(name)
%
% Keeps letters, digits, '-', '_' and '.'; every other run of characters (spaces, slashes, colons,
% anything a shell or another OS would choke on) becomes a single '_'. Leading/trailing '_' and '.'
% are dropped, so a name can never be '..' or climb out of the exports folder. An empty result
% comes back empty; the caller decides what that means.
%
% Shared by the export and the dialog that asks for the name, so the dialog can show exactly the
% folder that will be written.
name = char(strtrim(string(name)));
name = regexprep(name, '[^A-Za-z0-9._-]+', '_');
name = regexprep(name, '^[_.]+|[_.]+$', '');
end
