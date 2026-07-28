

for i=1:160

    load(strcat("CS_",num2str(i),".mat"))
    CS(i).trackBinding=trackBinding;
    CS(i).DwellTimes=trackDwellTimes;

end

CS=orderfields(CS,[1 2 3 4 11 22 5 7 6 10 8 9 12:19 21 23 20]);