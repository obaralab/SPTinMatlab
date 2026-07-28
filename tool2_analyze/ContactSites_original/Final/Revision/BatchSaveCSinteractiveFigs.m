
function BatchSaveCSinteractiveFigs(CSstruct,outputDir)

    if nargin==1
        mkdir CS_interactiveFigs
        outputDir=fullfile(pwd,'CS_interactiveFigs');
    end

    for i=1:size(CSstruct,2)
        fig=CS_interactiveFig(CSstruct,i);
        saveas(fig, fullfile(outputDir, ['CS_',num2str(i),'.fig']), 'fig');
        close(fig);
    end