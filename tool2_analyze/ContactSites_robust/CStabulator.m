
% Contact Site Tabulator

%Run in the "TrackData" Folder - Find the CS data by cell
Files=dir(fullfile(pwd,'*_CSdata.mat'));
files={Files.name}';

%Preallocate some memory to write into
T=table('Size',[size(Files,1) 3], 'VariableTypes', {'double','double','double'}, 'VariableNames',{'MitoCS','OtherCS','TotalCS'});
RowNames=cell(size(Files,1),1);
CSinfo=struct('cellname',[],'CSindex',[]);

for i=1:size(files,1)
   
   filename=char(files(i));
   load(filename,'CSdata');
   
   RowNames{i}=stripSuffix(filename,'_CSdata.mat');
   Mito=0;
   Other=0;
   index=NaN(size(CSdata));
   
   for j=1:size(CSdata,2)  
       if CSdata(j).MitoFlag
           Mito=Mito+1;
           index(j)=j;
       else
           Other=Other+1;
       end
   end
   
   T(i,:)={Mito,Other,size(CSdata,2)};
   
   if size(CSdata,2)~=(Mito+Other)
       error('You missed or double counted a CS!');
   end
   
   CSinfo(i).cellname=RowNames{i};
   CSinfo(i).CSindex=index(isfinite(index));
   
end

T.Properties.RowNames=RowNames;
% writetable(T,'CSstats.xlsx','WriteRowNames',true);
% save('CSindexing.mat','CSinfo');

% clear