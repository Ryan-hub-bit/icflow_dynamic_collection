#include "pin.H"
#include <iostream>
#include <fstream>
#include <unordered_map>
#include <unordered_set>
#include <mutex>
#include <string>
#include <filesystem>
#include <sstream>
#include <fcntl.h>
#include <sys/file.h>
#include "json.hpp"

using json = nlohmann::json;

// === Thread-safe data ===
std::mutex IndirectJumpMutex;
std::map<ADDRINT, std::unordered_set<ADDRINT>> IndirectJumpEdges;
std::map<ADDRINT, std::unordered_set<ADDRINT>> IndirectCallEdges;

ADDRINT textSectionBase = 0;
ADDRINT textSectionHigh = 0;
std::string mainImageName;

// === File lock utility ===
class FileLock {
private:
    int fd;
    bool locked;
    std::string filePath;

public:
    FileLock(const std::string& path) : fd(-1), locked(false), filePath(path) {
        fd = open(filePath.c_str(), O_WRONLY | O_CREAT, 0644);
    }
    ~FileLock() {
        if (locked) unlock();
        if (fd != -1) close(fd);
    }
    bool lock() {
        if (fd == -1) return false;
        return (locked = (flock(fd, LOCK_EX) == 0));
    }
    void unlock() {
        if (fd != -1 && locked) {
            flock(fd, LOCK_UN);
            locked = false;
        }
    }
};

// === Load existing JSON and merge ===
void LoadEdgesFromJSON(const std::string& filePath, std::map<ADDRINT, std::unordered_set<ADDRINT>>& edgeMap) {
    if (!std::filesystem::exists(filePath)) return;

    std::ifstream in(filePath);
    if (!in) return;

    json j;
    in >> j;
    in.close();

    for (auto& [key, value] : j.items()) {
        ADDRINT src = std::stoull(key, nullptr, 16);
        for (const auto& tgt_str : value) {
            ADDRINT tgt = std::stoull(tgt_str.get<std::string>(), nullptr, 16);
            edgeMap[src].insert(tgt);
        }
    }
}

// === Write JSON output ===
void SaveEdgesAsJSON(const std::string& path, const std::map<ADDRINT, std::unordered_set<ADDRINT>>& edgeMap) {
    FileLock lock(path);
    if (!lock.lock()) return;

    json j;
    for (const auto& [src, tgts] : edgeMap) {
        std::vector<std::string> tgt_list;
        for (ADDRINT tgt : tgts) {
            std::stringstream ss;
            ss << "0x" << std::hex << tgt;
            tgt_list.push_back(ss.str());
        }

        std::stringstream key;
        key << "0x" << std::hex << src;
        j[key.str()] = tgt_list;
    }

    std::ofstream out(path);
    out << j.dump(2) << std::endl;
    out.close();
    lock.unlock();
}

// === Runtime logging function ===
VOID RecordIndirectEdge(ADDRINT ip, ADDRINT tgt, BOOL isCall) {
    // Only record edges if both IP and TGT are inside main .text section
    if (ip < textSectionBase || ip >= textSectionHigh)
        return;
    if (tgt < textSectionBase || tgt >= textSectionHigh)
        return;

    std::lock_guard<std::mutex> guard(IndirectJumpMutex);
    if (isCall) {
        IndirectCallEdges[ip].insert(tgt);
    } else {
        IndirectJumpEdges[ip].insert(tgt);
    }
}

// === Image loading: track .text ===
VOID ImageLoad(IMG img, VOID* v) {
    if (IMG_IsMainExecutable(img)) {
        mainImageName = IMG_Name(img);
        for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec)) {
            if (SEC_Name(sec) == ".text") {
                textSectionBase = SEC_Address(sec);
                textSectionHigh = textSectionBase + SEC_Size(sec);
                break;
            }
        }
    }
}

// === Instruction instrumentation ===
VOID Instruction(INS ins, VOID* v) {
    if (!INS_IsIndirectControlFlow(ins))
        return;

    ADDRINT addr = INS_Address(ins);
    IMG img = IMG_FindByAddress(addr);

    if (IMG_Valid(img) &&
        IMG_IsMainExecutable(img) &&
        addr >= textSectionBase &&
        addr < textSectionHigh)
    {
        BOOL isCall = INS_IsCall(ins);
        INS_InsertCall(ins, IPOINT_TAKEN_BRANCH,
                       (AFUNPTR)RecordIndirectEdge,
                       IARG_INST_PTR,
                       IARG_BRANCH_TARGET_ADDR,
                       IARG_BOOL, isCall,
                       IARG_END);
    }
}

// === Fini: merge + save ===
VOID Fini(INT32, VOID*) {
    std::filesystem::path p(mainImageName);
    std::string base = p.filename().string();
    std::string dir = p.parent_path().string();

    std::string ijump = dir + "/" + base + "_ijump.json";
    std::string icall = dir + "/" + base + "_icall.json";

    LoadEdgesFromJSON(ijump, IndirectJumpEdges);
    LoadEdgesFromJSON(icall, IndirectCallEdges);

    SaveEdgesAsJSON(ijump, IndirectJumpEdges);
    SaveEdgesAsJSON(icall, IndirectCallEdges);
}

// === Main ===
int main(int argc, char* argv[]) {
    if (PIN_Init(argc, argv)) {
        std::cerr << "PIN init failed" << std::endl;
        return 1;
    }

    IMG_AddInstrumentFunction(ImageLoad, 0);
    INS_AddInstrumentFunction(Instruction, 0);
    PIN_AddFiniFunction(Fini, 0);

    PIN_StartProgram();
    return 0;
}

