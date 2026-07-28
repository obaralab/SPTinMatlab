

%Define ahead of time:
LUT=parula;%flipud(turbo);
Range=[0.175 0.250];
Steps=0.025;

A=Control.CSmatrix(:,:,2);
B=Control.CSmatrix(:,:,3);
C=Control.Deff;

X=HBSS.CSmatrix(:,:,2);
Y=HBSS.CSmatrix(:,:,3);
Z=HBSS.Deff;

figure
set(gcf,'Position',[100 100 1600 550]);


subplot(1,2,1)
colormap(LUT);
scatter(A(:),B(:),[],C(:),'filled');
xlim([-0.6 0.6]);
ylim([-0.6 0.6]);
caxis(Range);
hold on
plot(Control.refboundary(:,1)/1000,Control.refboundary(:,2)/1000,'r','LineWidth',1.5);

c=colorbar;
T=Range(1):Steps:Range(2);
c.Ticks=T;
set(gca,'FontSize',20);
c.Label.String='2D D_{eff} (\mum^2/sec)';

subplot(1,2,2)
colormap(LUT);
scatter(X(:),Y(:),[],Z(:),'filled');
xlim([-0.6 0.6]);
ylim([-0.6 0.6]);
caxis(Range);
hold on
plot(HBSS.refboundary(:,1)/1000,HBSS.refboundary(:,2)/1000,'r','LineWidth',1.5);

% figure
% set(gcf,'Position',[100 100 1600 750]);
% subplot(1,2,1)
% colormap(LUT);
% scatter(A(:),B(:),[],C(:),'filled');
% xlim([-0.6 0.6]);
% ylim([-0.6 0.6]);
% caxis(Range);
% subplot(1,2,2)
% colormap(LUT);
% scatter(X(:),Y(:),[],Z(:),'filled');
% xlim([-0.6 0.6]);
% ylim([-0.6 0.6]);
% caxis(Range);

c=colorbar;
T=Range(1):Steps:Range(2);
c.Ticks=T;
set(gca,'FontSize',20);
c.Label.String='2D D_{eff} (\mum^2/sec)';

