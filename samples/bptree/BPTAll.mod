MODULE BPTAll;

IMPORT Basic := BPTTest, Options := BPTOpts,
       Audit := BPTAudit, Out;
BEGIN
    Basic.Run;
    Options.Run;
    Audit.Run;
    Out.StringLn("BpTrees ALL TESTS OK")
END BPTAll.
