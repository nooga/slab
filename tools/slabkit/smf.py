"""Minimal Standard MIDI File reader: each track as notes (beat, length, pitch, velocity, channel), with names, programs and tempos."""
import struct, sys
GM=["Acoustic Grand","Bright Acoustic","Electric Grand","Honky-tonk","E.Piano 1","E.Piano 2","Harpsichord","Clavinet","Celesta","Glockenspiel","Music Box","Vibraphone","Marimba","Xylophone","Tubular Bells","Dulcimer","Drawbar Organ","Perc Organ","Rock Organ","Church Organ","Reed Organ","Accordion","Harmonica","Tango Acc","Nylon Gtr","Steel Gtr","Jazz Gtr","Clean Gtr","Muted Gtr","Overdrive Gtr","Distortion Gtr","Harmonics","Acoustic Bass","Fingered Bass","Picked Bass","Fretless","Slap 1","Slap 2","Synth Bass 1","Synth Bass 2","Violin","Viola","Cello","Contrabass","Tremolo Str","Pizzicato","Harp","Timpani","Strings","Slow Strings","Synth Str 1","Synth Str 2","Choir Aahs","Voice Oohs","Synth Voice","Orch Hit","Trumpet","Trombone","Tuba","Muted Tpt","French Horn","Brass Sect","Synth Brass 1","Synth Brass 2","Soprano Sax","Alto Sax","Tenor Sax","Bari Sax","Oboe","English Horn","Bassoon","Clarinet","Piccolo","Flute","Recorder","Pan Flute","Blown Bottle","Shakuhachi","Whistle","Ocarina","Square Lead","Saw Lead","Calliope","Chiff Lead","Charang","Voice Lead","Fifths Lead","Bass+Lead","New Age Pad","Warm Pad","Polysynth","Choir Pad","Bowed Pad","Metallic Pad","Halo Pad","Sweep Pad","Rain","Soundtrack","Crystal","Atmosphere","Brightness","Goblin","Echoes","Sci-fi","Sitar","Banjo","Shamisen","Koto","Kalimba","Bagpipe","Fiddle","Shanai","Tinkle Bell","Agogo","Steel Drums","Woodblock","Taiko","Melodic Tom","Synth Drum","Reverse Cymbal","Fret Noise","Breath","Seashore","Bird","Telephone","Helicopter","Applause","Gunshot"]
def vlq(d,i):
    v=0
    while True:
        b=d[i]; i+=1; v=(v<<7)|(b&0x7f)
        if b<0x80: return v,i
def read(path):
    d=open(path,'rb').read(); assert d[:4]==b'MThd'
    fmt,ntr,div=struct.unpack('>HHH',d[8:14]); i=14; tracks=[]; tempos=[]
    for tn in range(ntr):
        assert d[i:i+4]==b'MTrk'; ln=struct.unpack('>I',d[i+4:i+8])[0]; j=i+8; end=j+ln; i=end
        t=0; st=0; on={}; notes=[]; name=None; progs={}; texts=[]
        while j<end:
            dt,j=vlq(d,j); t+=dt; b=d[j]
            if b==0xff:
                typ=d[j+1]; l,k=vlq(d,j+2); data=d[k:k+l]; j=k+l
                if typ==3: name=data.decode('latin1')
                elif typ==0x51: tempos.append((t/div,60e6/int.from_bytes(data,'big')))
                elif typ in (1,5): texts.append((t/div,data.decode('latin1')))
                elif typ==0x58: tempos.append((t/div,f"TS {data[0]}/{2**data[1]}"))
                continue
            if b in (0xf0,0xf7):
                l,k=vlq(d,j+1); j=k+l; continue
            if b&0x80: st=b; j+=1
            hi=st&0xf0; ch=st&0x0f
            if hi in (0xc0,0xd0): a=d[j]; j+=1
            else: a,c=d[j],d[j+1]; j+=2
            if hi==0x90 and c>0: on[(ch,a)]=(t,c)
            elif hi==0x80 or (hi==0x90 and c==0):
                if (ch,a) in on: s0,v=on.pop((ch,a)); notes.append((s0/div,(t-s0)/div,a,v,ch))
            elif hi==0xc0: progs.setdefault(ch,a)
        tracks.append(dict(name=name,notes=notes,progs=progs,texts=texts))
    return div,tracks,tempos
if __name__=="__main__":
    div,tr,tempos=read(sys.argv[1]); print("div",div,"tempos",tempos[:6])
    for k,t in enumerate(tr):
        chs=sorted({n[4] for n in t['notes']})
        first=min((n[0] for n in t['notes']),default=None)
        print(k,repr(t['name']),"notes",len(t['notes']),"ch",chs,"prog",{c:GM[p] for c,p in t['progs'].items()},"first",first, "range",(min((n[2] for n in t['notes']),default=0),max((n[2] for n in t['notes']),default=0)))
