FROM golang:1.15
WORKDIR /go/src/github.com/
COPY main.go .
RUN go mod init main-hook
RUN go get k8s.io/client-go@v0.17.2
RUN go test 
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o app .

FROM alpine:latest  
RUN apk --no-cache add ca-certificates
WORKDIR /root/
COPY --from=0 /go/src/github.com/app .
RUN pwd
RUN ls -ltr
CMD ["/root/app"] 
